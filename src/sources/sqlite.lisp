;;;
;;; Tools to handle the SQLite Database
;;;

(in-package :pgloader.sqlite)

(defvar *sqlite-db* nil
  "The SQLite database connection handler.")

;;;
;;; SQLite tools connecting to a database
;;;
(defstruct (coldef
	     (:constructor make-coldef (seq name type nullable default pk-id)))
  seq name type nullable default pk-id)

(defmethod format-pgsql-column ((col coldef) &key identifier-case)
  "Return a string representing the PostgreSQL column definition."
  (let* ((column-name
	  (apply-identifier-case (coldef-name col) identifier-case))
	 (type-definition
	  (format nil
		  "~a~:[~; not null~]~@[ default ~a~]"
		  (coldef-type col)
		  (coldef-nullable col)
		  (coldef-default col))))
    (format nil "~a ~22t ~a" column-name type-definition)))

(defun list-tables (&optional (db *sqlite-db*))
  "Return the list of tables found in SQLITE-DB."
  (let ((sql "SELECT tbl_name FROM sqlite_master WHERE type='table'"))
    (loop for (name) in (sqlite:execute-to-list db sql)
       collect name)))

(defun list-columns (table-name &optional (db *sqlite-db*))
  "Return the list of columns found in TABLE-NAME."
  (let ((sql (format nil "PRAGMA table_info(~a)" table-name)))
    (loop for (seq name type nullable default pk-id) in
	 (sqlite:execute-to-list db sql)
       collect (make-coldef seq name type (= 1 nullable) default pk-id))))

(defun list-all-columns (&optional (db *sqlite-db*))
  "Get the list of SQLite column definitions per table."
  (loop for table-name in (list-tables db)
     collect (cons table-name (list-columns table-name db))))

(defun list-all-indexes (&optional (db *sqlite-db*))
  "Get the list of SQLite index definitions per table."
  (let ((sql "SELECT name, tbl_name, sql FROM sqlite_master WHERE type='index'"))
    (loop with schema = nil
       for (index-name table-name sql) in (sqlite:execute-to-list db sql)
	 do (let ((entry  (assoc table-name schema :test 'equal))
		  (idxdef (cons index-name sql)))
	      (if entry
		  (push idxdef (cdr entry))
		  (push (cons table-name (list idxdef)) schema)))
       finally (return (reverse (loop for (name . indexes) in schema
				     collect (cons name (reverse indexes))))))))


;;;
;;; Integration with the pgloader Source API
;;;
(defclass copy-sqlite (copy)
  ((db :accessor db :initarg :db))
  (:documentation "pgloader SQLite Data Source"))

(defmethod initialize-instance :after ((source copy-sqlite) &key)
  "Add a default value for transforms in case it's not been provided."
  (let* ((source-db  (slot-value source 'source-db))
	 (db         (sqlite:connect source-db))
	 (table-name (when (slot-boundp source 'source)
		       (slot-value source 'source)))
	 (fields     (or (and (slot-boundp source 'fields)
			      (slot-value source 'fields))
			 (when table-name
			   (list-columns table-name db))))
	 (transforms (when (slot-boundp source 'transforms)
		       (slot-value source 'transforms))))

    ;; we will reuse the same SQLite database handler that we just opened
    (setf (slot-value source 'db) db)

    ;; default to using the same table-name as source and target
    (when (and table-name
	       (or (not (slot-boundp source 'target))
		   (slot-value source 'target)))
      (setf (slot-value source 'target) table-name))

    (when fields
      (unless (slot-boundp source 'fields)
	(setf (slot-value source 'fields) fields))

      (unless transforms
	(setf (slot-value source 'transforms)
	      (loop for field in fields
		 if (string-equal "float" (coldef-type field))
		 collect #'pgloader.transforms::float-to-string
		 else
		 collect nil))))))

;;;
;;; Map a function to each row extracted from SQLite
;;;
(defmethod map-rows ((sqlite copy-sqlite) &key process-row-fn)
  "Extract SQLite data and call PROCESS-ROW-FN function with a single
   argument (a list of column values) for each row"
  (let ((sql (format nil "SELECT * FROM ~a" (source sqlite))))
   (loop
      with statement = (sqlite:prepare-statement (db sqlite) sql)
      with column-numbers =
	(loop for i from 0
	   for name in (sqlite:statement-column-names statement)
	   collect i)
      while (sqlite:step-statement statement)
      for row = (mapcar (lambda (x)
			  (sqlite:statement-column-value statement x))
			column-numbers)
      do (funcall process-row-fn row)
      finally (sqlite:finalize-statement statement))))


(defmethod copy-to-queue ((sqlite copy-sqlite) dataq)
  "Copy data from SQLite table TABLE-NAME within connection DB into queue DATAQ"
  (let ((read (pgloader.queue:map-push-queue dataq #'map-rows sqlite)))
    (pgstate-incf *state* (target sqlite) :read read)))

(defmethod copy-from ((sqlite copy-sqlite) &key (kernel nil k-s-p) truncate)
  "Stream the contents from a SQLite database table down to PostgreSQL."
  (let* ((summary  (null *state*))
	 (*state*     (or *state* (pgloader.utils:make-pgstate)))
	 (lp:*kernel* (or kernel (make-kernel 2)))
	 (channel     (lp:make-channel))
	 (dataq       (lq:make-queue :fixed-capacity 4096))
	 (table-name  (target sqlite))
	 (pg-dbname   (target-db sqlite)))

    (with-stats-collection (pg-dbname table-name :state *state* :summary summary)
      (log-message :notice "COPY ~a" table-name)
      ;; read data from SQLite
      (lp:submit-task channel #'copy-to-queue sqlite dataq)

      ;; and start another task to push that data from the queue to PostgreSQL
      (lp:submit-task channel
		      #'pgloader.pgsql:copy-from-queue
		      pg-dbname table-name dataq
		      :truncate truncate
		      :transforms (transforms sqlite))

      ;; now wait until both the tasks are over
      (loop for tasks below 2 do (lp:receive-result channel)
	 finally
	   (log-message :info "COPY ~a done." table-name)
	   (unless k-s-p (lp:end-kernel))))))

(defun create-indexes-in-kernel (dbname indexes kernel channel
				 &key include-drop state (label "create index"))
  "Create indexes for given table in dbname, using given lparallel KERNEL
   and CHANNEL so that the index build happen in concurrently with the data
   copying."
  (let* ((lp:*kernel* kernel))
    (pgstate-add-table state dbname label)

    (when include-drop
      (let ((drop-channel (lp:make-channel))
	    (drop-indexes
	     (loop for (name . sql) in indexes
		collect (format nil "DROP INDEX IF EXISTS ~a;" name))))
	(loop
	   for sql in drop-indexes
	   do
	     (log-message :notice "~a" sql)
	     (lp:submit-task drop-channel
			     #'pgsql-execute-with-timing
			     dbname label sql state))

	;; wait for the DROP INDEX to be done before issuing CREATE INDEX
	(loop for idx in drop-indexes do (lp:receive-result drop-channel))))

    (loop
       for (name . sql) in indexes
       do
	 (log-message :notice "~a" sql)
	 (lp:submit-task channel
			 #'pgsql-execute-with-timing
			 dbname label sql state))))

(defmethod copy-database ((sqlite copy-sqlite)
			  &key
			    truncate
			    schema-only
			    create-tables
			    include-drop
			    create-indexes
			    reset-sequences
			    only-tables)
  "Stream the given SQLite database down to PostgreSQL."
  (let* ((*state*       (make-pgstate))
	 (idx-state     (make-pgstate))
	 (seq-state     (make-pgstate))
         (copy-kernel   (make-kernel 2))
         (all-columns   (list-all-columns (db sqlite)))
         (all-indexes   (list-all-indexes (db sqlite)))
         (max-indexes   (loop for (table . indexes) in all-indexes
                           maximizing (length indexes)))
         (idx-kernel    (when (and max-indexes (< 0 max-indexes))
			  (make-kernel max-indexes)))
         (idx-channel   (when idx-kernel
			  (let ((lp:*kernel* idx-kernel))
			    (lp:make-channel))))
	 (pg-dbname     (target-db sqlite)))

    ;; if asked, first drop/create the tables on the PostgreSQL side
    (when create-tables
      (log-message :notice "~:[~;DROP then ~]CREATE TABLES" include-drop)
      (with-pgsql-transaction (pg-dbname)
	(create-tables all-columns :include-drop include-drop)))

    (loop
       for (table-name . columns) in all-columns
       when (or (null only-tables)
		(member table-name only-tables :test #'equal))
       do
	 (let ((table-source
		(make-instance 'copy-sqlite
			       :db         (db sqlite)
			       :source-db  (source-db sqlite)
			       :target-db  pg-dbname
			       :source     table-name
			       :target     table-name
			       :fields     columns)))
	   ;; first COPY the data from SQLite to PostgreSQL, using copy-kernel
	   (unless schema-only
	     (copy-from table-source :kernel copy-kernel :truncate truncate))

	   ;; Create the indexes for that table in parallel with the next
	   ;; COPY, and all at once in concurrent threads to benefit from
	   ;; PostgreSQL synchronous scan ability
	   ;;
	   ;; We just push new index build as they come along, if one
	   ;; index build requires much more time than the others our
	   ;; index build might get unsync: indexes for different tables
	   ;; will get built in parallel --- not a big problem.
	   (when create-indexes
	     (let* ((indexes
		     (cdr (assoc table-name all-indexes :test #'string=))))
	       (create-indexes-in-kernel pg-dbname indexes
					 idx-kernel idx-channel
					 :state idx-state
					 :include-drop include-drop)))))

    ;; don't forget to reset sequences, but only when we did actually import
    ;; the data.
    (when (and (not schema-only) reset-sequences)
      (let ((tables (or only-tables
			(mapcar #'car all-columns))))
	(log-message :notice "Reset sequences")
	(with-stats-collection (pg-dbname "reset sequences"
					  :use-result-as-rows t
					  :state seq-state)
	  (pgloader.pgsql:reset-all-sequences pg-dbname :tables tables))))

    ;; now end the kernels
    (let ((lp:*kernel* idx-kernel))  (lp:end-kernel))
    (let ((lp:*kernel* copy-kernel))
      ;; wait until the indexes are done being built...
      ;; don't forget accounting for that waiting time.
      (with-stats-collection (pg-dbname "index build completion" :state *state*)
	(loop for idx in all-indexes do (lp:receive-result idx-channel)))
      (lp:end-kernel))

    ;; and report the total time spent on the operation
    (report-summary)
    (format t pgloader.utils::*header-line*)
    (report-summary :state idx-state :header nil :footer nil)
    (report-summary :state seq-state :header nil :footer nil)
    ;; don't forget to add up the RESET SEQUENCES timings
    (incf (pgloader.utils::pgstate-secs *state*)
	  (pgloader.utils::pgstate-secs seq-state))
    (report-pgstate-stats *state* "Total streaming time")))
