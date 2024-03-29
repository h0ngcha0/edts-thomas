;;; edts.el --- Misc edts-related functionality.

;; Copyright 2012-2013 Thomas Järvstrand <tjarvstrand@gmail.com>

;; Author: Thomas Järvstrand <thomas.jarvstrand@gmail.com>
;; Keywords: erlang
;; This file is not part of GNU Emacs.

;;
;; This file is part of EDTS.
;;
;; EDTS is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Lesser General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; EDTS is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Lesser General Public License for more details.
;;
;; You should have received a copy of the GNU Lesser General Public License
;; along with EDTS. If not, see <http://www.gnu.org/licenses/>.

(defcustom edts-erl-command
  (or (executable-find "erl")
      (null
        (warn
         "No erl on exec-path. Most of EDTS' functionality will be broken.")))
  "Location of the erl-executable to use when launching the main EDTS-
node."
  :group 'edts)

(defconst edts-erl-root
  (and edts-erl-command
       (file-name-directory
        (directory-file-name
         (file-name-directory (file-truename edts-erl-command)))))
  "Location of the Erlang root directory")

(defcustom edts-data-directory
  (if (boundp 'user-emacs-directory)
      (expand-file-name (concat user-emacs-directory "/edts"))
      (expand-file-name "~/.emacs.d"))
  "Where EDTS should save its data.")

(defvar edts-find-macro-regexp
  "\\(\\(\\('.*'\\)\\|\\([a-zA-Z0-9_@]*\\)\\)[\\s-]*\\((.*)\\)?\\)"
  "Regexp describing a macro name")

(defconst edts-find-macro-definition-regexp
  (format "^-define\\s-*(%s,\\s-*\\(.*\\))." edts-find-macro-regexp)
  "Regexp describing a macro definition")

(defvar edts-buffer-node-name nil
  "The node-name of current-buffer")
(make-variable-buffer-local 'edts-buffer-node-name)

(defvar edts-after-node-init-hook nil
  "Hooks to run after a node has been initialized.")


(defun edts-buffer-node-name ()
  "Print the node sname of the erlang node connected to current
buffer. The node is either:
- The module's project node, if current buffer is an erlang module, or
- The buffer's erlang node if buffer is an edts-shell buffer.
- The project-node of the buffer that was current buffer before jumping
  to the current buffer if the file of the current buffer is located outside
  any project (eg. an \"externally\" loaded module such as an otp-module or a
  module loaded by ~/.erlang)."
  (interactive)
  (message "%s" (edts-node-name)))

(defun edts-find-module-macros ()
  (let* ((files  (cons (buffer-file-name) (edts-get-includes)))
         (macros   (apply #'append
                          (mapcar #'edts-get-file-macros files)))
         (parsed  (edts-parse-macros macros)))
    parsed))


(defun edts-parse-macros (raw-macros)
  (when raw-macros
    (let* (;; Raw macro strings: '("MACRO1" "MACRO2(ARG21,..., ARG2X)")
           (arity-macros (mapcar #'(lambda (m) (cdr (assoc 'string m)))
                                 raw-macros))
           ;; (("MACRO1" 0) ("MACRO2" X))
           (arity-macro-strings (mapcar #'(lambda (m)
                                            (cons (cdr (assoc 'function m))
                                                  (cdr (assoc 'arity    m))))
                                        (edts-get-mfas arity-macros))))
      (loop for raw-m in raw-macros collect
            (let* ((name      (cdr (assoc 'name raw-m)))
                   (args      (cdr (assoc 'args raw-m)))
                   (value     (cdr (assoc 'value raw-m)))
                   (raw-str   (cdr (assoc 'string raw-m)))
                   (arity     (cdr (assoc-string name arity-macro-strings)))
                   (arity-str (format "%s/%s" name arity))
                   (doc       (format "%s -> %s" raw-str value)))
              (cons arity-str doc))))))


(defun edts-get-file-macros (file-name)
  (with-temp-buffer
    (insert-file-contents file-name)
    (edts-get-macros)))

(defun edts-get-macros ()
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (let ((macros nil))
        (while (re-search-forward edts-find-macro-definition-regexp nil t)
            (push
             `((string . ,(match-string-no-properties 1))
               (name   . ,(match-string-no-properties 2))
               (args   . ,(match-string-no-properties 5))
               (value  . ,(match-string-no-properties 6)))
             macros)
            (goto-char (match-end 0)))
        macros))))

(defun edts-mfa-at (&optional point)
  "Find mfa under POINT. POINT defaults to current point."
  (goto-char (or point (point)))
  (save-excursion
    (save-match-data
      (let* ((start (save-excursion
                      (skip-chars-backward "a-zA-Z0-9_:'")
                      (point)))
             (end   (save-excursion
                      (ferl-goto-end-of-call-name)
                      (forward-sexp)
                      (point)))
             (str   (buffer-substring-no-properties start end)))
        (car (edts-strings-to-mfas (list str)))))))

(defun edts-strings-to-mfas (strs)
  "Return a list with each string in STRS parsed to an mfa."
  (mapcar #'edts--fix-mfa-mod (edts-get-mfas strs)))

(defun edts--fix-mfa-mod (mfa)
  (let ((m (cdr (assoc 'module mfa)))
        (f (cdr (assoc 'function mfa)))
        (a (cdr (assoc 'arity mfa))))
    (unless m
      (loop named import
            for (module . imported) in (erlang-get-import) do
            (when (eq a (cdr (assoc f imported)))
              (return-from import module))))
    (if m
        (list m f a)
      (list (erlang-get-module) f a))))

(defun edts-search-function (function arity)
  "Goto the definition of FUNCTION/ARITY in the current buffer."
  (let ((origin (point))
        (re (concat "^" function "\s*("))
        (match nil))
    (goto-char (point-min))
    (while (and (null match) (re-search-forward re nil t))
      (goto-char (match-beginning 0))
      (ferl-goto-end-of-call-name)
      (when (eq arity (car (last (edts-mfa-at (point)))))
        (setq match t)))
    (if match
        (beginning-of-line)
      (goto-char origin)
      (error "function %s/%s not found" function arity))))


(defun edts-query (prompt choices &optional error-msg)
  "Query the user for a choice"
  (let ((choice (ido-completing-read prompt choices)))
    (if (member choice choices)
        choice
      (error (or error-msg "Invalid choice")))))

(defun edts-find-doc ()
  "Find and show the man-page documentation for a function."
  (interactive)
  (let* ((module
          (edts-query "Module: " (edts-man-modules)))
         (fun-strings (edts-man-module-function-entries module))
         (fun (edts-query "Function: " (cons "-Top of Chapter-" fun-strings))))
    (if (string= fun "-Top of Chapter-")
        (edts-man-find-module module)
        (let* ((split     (split-string fun "/"))
               (fun-name  (car split))
               (fun-arity (string-to-number (cadr split))))
          (edts-man-find-function-entry module fun-name fun-arity)))))

(defun edts-show-doc-under-point ()
  "Find and display the man-page documentation for function under point
in a tooltip."
  (interactive)
  (let* ((mfa      (edts-mfa-at (point)))
         (module   (car mfa))
         (function (cadr mfa))
         (arity    (caddr mfa)))
    (edts-show-tooltip
     (condition-case ex
        (edts-man-extract-function-entry module function)
        ('error
         (edts-extract-doc-from-source module function arity))))))

(defun edts-show-tooltip (text)
  "Show a tooltip using either popup.el or pos-tip.el"
  (condition-case ex
      (pos-tip-show text nil nil nil -1)
    ('error
     (popup-tip text))))

(defun edts-extract-doc-from-source (module function arity)
  "Find documentation for MODULE:FUNCTION/ARITY"
  (let ((source (cdr (assoc 'source (edts-get-basic-module-info module)))))
    (if source
        (edts-doc-extract-function-information-from-source source
                                                           function
                                                           arity)
      (null (edts-log-error "No such module: %s" module)))))

(defun edts-function-head-regexp (function &optional arity)
  "Construct a regexp matching FUNCTION(arg1, ..., argARITY). A negative number
for ARITY will give a regexp matching any arity."
  (unless arity (setq arity -1))
  (format "%s[[:space:]\n]*(%s)" function (edts-argument-regexp arity)))

(defun edts-function-regexp (function &optional arity)
  "Construct a regexp matching 'FUNCTION(arg1, ..., argARITY) ->'.
negative number for ARITY will give a regexp matching any arity."
  (concat (edts-function-head-regexp function arity) "[[:space:]\n]*->"))

(defun edts-any-function-regexp ()
  "Construct a regexp matching any function."
  ;; Kind of broken for strings, comments and single quoted atoms
  (format "\\(%s[[:space:]\n]*(.*)\\)[[:space:]]*->" erlang-atom-regexp))

(defun edts-argument-regexp (arity)
  "Contstruct a regexp matching ARITY arguments. A negative number
for ARITY will give a regexp matching any arity."
  (cond
   ((< arity 0) "[[:ascii:]]*?")
   ((equal arity 0) "[[:space:]]*")
   ((concat "[^,]*?" (apply #'concat (make-list (- arity 1) ",[^,]*?"))))))

(defun edts-ahs-edit-current-function ()
  "Activate ahs-edit-mode with erlang-current-function range-plugin."
  (interactive)
  (ahs-onekey-edit-function 'erlang-current-function nil))

(defun edts-ahs-edit-buffer ()
  "Activate ahs-edit-mode with ahs-range-whole-buffer range-plugin."
  (interactive)
  (ahs-onekey-edit-function 'whole-buffer nil))


(defun edts-ensure-server-started ()
  "Starts an edts server-node in a comint-buffer unless it is already running."
  (unless (or (edts-node-started-p "edts") (edts-start-server))
    (error "EDTS: Could not start main server")))

(defun edts-start-server ()
  "Starts an edts server-node in a comint-buffer"
  (interactive)
  (when (edts-node-started-p "edts")
    (error "EDTS: Server already running"))
  (let* ((pwd (path-util-join (directory-file-name edts-lib-directory) ".."))
         (command (list "./start" edts-data-directory edts-erl-command))
         (retries 10)
         started
         available)
    (edts-shell-make-comint-buffer "*edts*" "edts" pwd command)
    (while (and (> retries 0) (or (not started)
                                  (not available)))
      (setq started (edts-node-started-p "edts"))
      (setq available (edts-get-nodes t))
      (sit-for 0.5)
      (decf retries))
    available))

(defun edts-ensure-node-not-started (node-name)
  "Signals an error if a node of name NODE-NAME is running on
localhost."
  (when (edts-node-started-p node-name)
    (error "Node already started")))

(defun edts-node-started-p (name)
  "Syncronously query epmd to see whether it has a node with NAME registered."
  (condition-case ex
      (with-temp-buffer
        (let ((socket (open-network-stream "epmd" (current-buffer) "0" 4369))
              (process (get-buffer-process (current-buffer))))
          (set-process-query-on-exit-flag process nil)
          (process-send-string socket (edts-build-epmd-message "n"))
          (accept-process-output socket 0.5))
        (member name (edts-nodenames-from-string (buffer-string))))
    ('file-error nil)))

(defun edts-nodenames-from-string (string)
  "Convert the epmd reply STRING into a list of nodenames."
  (setq string (split-string (substring string 4)))
  (let ((names  nil))
    (while string
      (when (string-equal (car string) "name")
        (setq names (cons (cadr string) names)))
      (setq string (cdr string)))
    names))

(defun edts-build-epmd-message (msg)
  "Build a message for the epmd from MSG. Logic taken from distel's epmd.el."
  (let* ((len (length msg))
         (len-msb (ash len -8))
         (len-lsb (logand len 255)))
    (concat (string len-msb len-lsb) msg)))

(defun edts-init-node-when-ready (project-name
                                  node-name
                                  root
                                  libs
                                  &optional
                                  app-include-dirs
                                  project-include-dirs)
  "Once NODE-NAME is registered with epmd, register it with the edts"
  (let ((retries 5))
    (edts-log-debug "Waiting for node %s to start, (retries %s)"
                    node-name
                    retries)
    (while (and (> retries 0) (not (edts-node-started-p node-name)))
      (sleep-for 0.5)
      (decf retries))
    (if (not (edts-node-started-p node-name))
        (null (edts-log-error "Node %s failed to start." node-name))
      (edts-init-node project-name
                      node-name
                      root
                      libs
                      app-include-dirs
                      project-include-dirs)
      (run-hooks 'edts-after-node-init-hook))))

(defun edts-init-node-async (project-name
                             node-name
                             root
                             libs
                             app-include-dirs
                             project-include-dirs)
  "Register NODE-NAME with the EDTS server asynchronously."
  (interactive (list (eproject-attribute :name)
                     (edts-node-name)
                     (eproject-attribute :root)
                     (eproject-attribute :lib-dirs)
                     (eproject-attribute :app-include-dirs)
                     (eproject-attribute :project-include-dirs)))
  (let* ((resource (list "nodes" node-name))
         (args     (list (cons "project_name"         project-name)
                         (cons "project_root"         root)
                         (cons "project_lib_dirs"     libs)
                         (cons "app_include_dirs"     app-include-dirs)
                         (cons "project_include_dirs" project-include-dirs)))
         (cb-args  (list node-name)))
    (edts-rest-post-async resource
                          args
                          #'edts-init-node-async-callback
                          cb-args)))

(defun edts-init-node-async-callback (reply node-name &rest rest)
  "Handle the result of an asynchronous node registration."
  (let ((result (cadr (assoc 'result reply))))
    (if (and result (eq (string-to-number result) 201))
        (edts-log-debug "Successfuly intialized node %s" node-name)
      (null
       (edts-log-error "Failed to initialize node %s" node-name)))))

(defun edts-init-node (project-name
                       node-name
                       root
                       libs
                       app-include-dirs
                       project-include-dirs)
  "Register NODE-NAME with the EDTS server.

If called interactively, fetch arguments from project of
current-buffer."
  (interactive (list (eproject-attribute :name)
                     (edts-node-name)
                     (eproject-attribute :root)
                     (eproject-attribute :lib-dirs)
                     (eproject-attribute :app-include-dirs)
                     (eproject-attribute :project-include-dirs)))
  (let ((retries 5))
    (while (and (> retries 0)
                (not (edts-try-init-node project-name
                                         node-name
                                         root
                                         libs
                                         app-include-dirs
                                         project-include-dirs)))
      (edts-log-error "Failed to register node %s, Retrying (%s attempts left)"
                      node-name
                      retries)
      (decf retries))
    (if (edts-node-registeredp node-name t)
        t
      (null (edts-log-error "Failed to register node '%s'" node-name)))))

(defun edts-try-init-node (project-name
                           node-name
                           root
                           libs
                           app-include-dirs
                           project-include-dirs)
  "Initialize NODE-NAME with the edts node."
  (edts-log-debug "Registering node %s, (retries %s)" node-name retries)
  (let* ((resource (list "nodes" node-name))
         (args     (list (cons "project_name"         project-name)
                         (cons "project_root"         root)
                         (cons "project_lib_dirs"     libs)
                         (cons "app_include_dirs"     app-include-dirs)
                         (cons "project_include_dirs" project-include-dirs)))
         (res      (edts-rest-post resource args)))
    (if (equal (cdr (assoc 'result res)) '("201" "Created"))
        res
      (null (edts-log-error "Unexpected reply: %s"
                            (cdr (assoc 'result res)))))))


(defun edts-get-who-calls (module function arity)
  "Fetches a list of all function calling  MODULE:FUNCTION/ARITY on
current buffer's project node."
  (let* ((resource (list "nodes" (edts-node-name)
                         "modules" module
                         "functions" function
                         (number-to-string arity)
                         "callers"))
         (res      (edts-rest-get resource nil)))
    (if (equal (assoc 'result res) '(result "200" "OK"))
        (cdr (assoc 'body res))
        (null
         (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))

(defun edts-get-function-info (module function arity)
  "Fetches info MODULE on the current buffer's project node associated with
current buffer."
  (let* ((resource (list "nodes"     (edts-node-name)
                         "modules"   module
                         "functions" function
                         (number-to-string arity)))
         (res      (edts-rest-get resource nil)))
    (if (equal (assoc 'result res) '(result "200" "OK"))
        (cdr (assoc 'body res))
        (null
         (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))

(defun edts-get-modules ()
  "Fetches all available erlang modules for the node associated with
current buffer."
  (let* ((resource (list "nodes" (edts-node-name) "modules"))
         (res      (edts-rest-get resource nil)))
    (if (equal (assoc 'result res) '(result "200" "OK"))
        (cdr (assoc 'body res))
        (null
         (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))

(defun edts-get-module-exports (module &optional no-error)
  "Fetches all exported functions of MODULE on the node associated with
current buffer. Does not fetch detailed information about the individual
functions. If NO-ERROR is non-nil, don't report an error if the request
fails."
  (let* ((resource (list "nodes" (edts-node-name)
                         "modules" module))
         (res      (edts-rest-get resource '(("info_level" . "basic")))))
    (if (equal (assoc 'result res) '(result "200" "OK"))
          (cdr (assoc 'exports (cdr (assoc 'body res))))
      (unless no-error
        (null
         (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res))))))))

(defun edts-function-to-string (function-struct)
  "Convert FUNCTION-STRUCT to a string of <function>/<arity>."
  (format "%s/%s"
          (cdr (assoc 'function function-struct))
          (cdr (assoc 'arity    function-struct))))

(defun edts-get-basic-module-info (module)
  "Fetches basic info about module on the node associated with current buffer"
  (edts-get-module-info (edts-node-name) module 'basic))

(defun edts-get-detailed-module-info (module)
  "Fetches detailed info about MODULE on the node associated with current
buffer"
  (edts-get-module-info (edts-node-name) module 'detailed))

(defun edts-get-free-vars (snippet)
  "Return a list of the free variables in SNIPPET."
  (let* ((resource (list "code" "free_vars"))
         (res      (edts-rest-get resource nil snippet)))
    (if (equal (assoc 'result res) '(result "200" "OK"))
        (cdr (assoc 'vars (cdr (assoc 'body res))))
        (null
         (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))

(defun edts-get-mfas (snippets)
  "Return a each code snippet in SNIPPETS parsed as an mfa."
  (let* ((resource (list "code" "parsed_expressions" "mfa"))
         (res      (edts-rest-get resource nil snippets)))
    (if (equal (assoc 'result res) '(result "200" "OK"))
        (cdr (assoc 'body res))
        (null
         (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))


(defun edts-get-module-info (node module level)
  "Fetches info about MODULE on NODE LEVEL is either basic or detailed."
  (let* ((resource (list "nodes" node "modules" module))
         (args     (list (cons "info_level" (symbol-name level))))
         (res      (edts-rest-get resource args)))
    (if (equal (assoc 'result res) '(result "200" "OK"))
        (cdr (assoc 'body res))
        (null
         (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))

(defun edts-get-module-xref-analysis-async (modules checks callback)
  "Run xref-checks on MODULE on the node associated with current buffer,
asynchronously. When the request terminates, call CALLBACK with the
parsed response as the single argument"
  (let* ((node-name (edts-node-name))
         (resource  (list "nodes" node-name
                          "xref_analysis"))
         (rest-args `(("xref_checks" . ,(mapcar #'symbol-name checks))
                      ("modules"     . ,modules)))
         (cb-args   (list callback 200)))
    (edts-log-debug
     "fetching xref-analysis of %s async on %s" modules node-name)
    (edts-rest-get-async resource rest-args #'edts-async-callback cb-args)))

(defun edts-get-module-eunit-async (module callback)
  "Run eunit tests in MODULE on the node associated with current-buffer,
asynchronously. When the request terminates, call CALLBACK with the
parsed response as the single argument."
  (let* ((node-name (edts-node-name))
         (resource      (list "nodes"   node-name
                              "modules" module "eunit"))
         (cb-args (list callback 200)))
    (edts-log-debug
     "running eunit tests in %s async on %s" module node-name)
    (edts-rest-get-async resource nil #'edts-async-callback cb-args)))


(defun edts-compile-and-load-async (module file callback)
  "Compile MODULE in FILE on the node associated with current buffer,
asynchronously. When the request terminates, call CALLBACK with the
parsed response as the single argument."
  (let* ((node-name   (edts-node-name))
         (resource    (list "nodes" node-name "modules" module))
         (rest-args   (list (cons "file" file)))
         (cb-args     (list callback 201)))
    (edts-log-debug "Compiling %s async on %s" module node-name)
    (edts-rest-post-async resource rest-args #'edts-async-callback cb-args)))

(defun edts-get-dialyzer-analysis-async (modules otp-plt out-plt callback)
  "Run dialyzer analysis on MODULES on the node associated with
current-buffer asynchronously. When the request terminates, call
CALLBACK with the parsed response as the single argument."
  (let* ((node-name (edts-node-name))
         (resource (list "nodes"   node-name
                         "dialyzer_analysis"))
         (args     `(("modules" . ,modules)
                     ("otp_plt" . ,otp-plt)
                     ("out_plt" . ,out-plt)))
         (cb-args (list callback 200)))
    (edts-log-debug
     "running dialyzer on %s async on %s" modules node-name)
    (edts-rest-get-async resource args #'edts-async-callback cb-args)))


(defun edts-async-callback (reply callback expected &rest args)
  "Generic callback-function for handling the reply of rest-requests.
If the http return-code (an integer) of REPLY equals EXPECTED, call
CALLBACK with the http-body part of REPLY as the first argument and
ARGS as the other arguments"
  (let ((result (cadr (assoc 'result reply))))
    (if (and result (eq (string-to-number result) expected))
        (when callback
          (apply callback (cdr (assoc 'body reply)) args))
      (null
       (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result reply)))))))

(defun edts-get-includes (&optional module)
  "Get all includes of module in current-buffer from the node
associated with that buffer."
  (let ((info (edts-get-detailed-module-info (or module (ferl-get-module)))))
    (cdr (assoc 'includes info)))) ;; Get all includes

(defun edts-toggle-breakpoint (node-name module line)
  "Add/remove breakpoint in MODULE at LINE. This does not imply that MODULE becomes
interpreted."
  (let* ((resource
          (list "debugger" node-name "breakpoints" module line))
         (args '())
         (res (edts-rest-post resource args)))
    (if (equal (assoc 'result res) '(result "201" "Created"))
        (cdr (assoc 'body res))
      (null (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))

(defun edts-get-breakpoints (node-name)
  "Get all breakpoints and related info on NODE-NAME."
  (let* ((resource
          (list "debugger" node-name "breakpoints"))
         (args '())
         (res (edts-rest-get resource args)))
    (if (equal (assoc 'result res) '(result "200" "OK"))
        (cdr (assoc 'body res))
      (null (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))

(defun edts-wait-for-debugger (node-name)
  "Wait for the debugger to attach and return the current interpreter state"
  (edts--send-debugger-command-async node-name "wait_for_debugger"
                                     #'(lambda (result)
                                         (if (equal (assoc 'result result)
                                                    '(result "200" "OK"))
                                             (edts-debug-handle-debugger-reply
                                              (cdr (assoc 'body result)))))))

(defun edts-step-into (node-name)
  "When debugging, perform a step-into"
  (edts--send-debugger-command node-name "debugger_step"))

(defun edts-continue (node-name)
  "When debugging, continue execution until the next breakpoint or termination"
  (edts--send-debugger-command node-name "debugger_continue"))

(defun edts-step-out (node-name)
  "When debugging, step out of the current function"
  (edts--send-debugger-command node-name "debugger_step_out"))

(defun edts-debug-stop (node-name)
  "Stop debugging"
  (edts--send-debugger-command node-name "debugger_stop"))

(defun edts--send-debugger-command (node-name command)
  "Convenience function to send COMMAND to the debugger at NODE-NAME"
  (let* ((resource
          (list "debugger" node-name))
         (args (list (cons "cmd" command)))
         (res (edts-rest-post resource args)))
    (if (equal (assoc 'result res) '(result "201" "Created"))
        (cdr (assoc 'body res))
      (null (edts-log-error "Unexpected reply: %s" (cdr (assoc 'result res)))))))

(defun edts--send-debugger-command-async (node-name command callback)
  "Convenience function to send COMMAND to the debugger at NODE-NAME,
executing CALLBACK when a reply is received"
  (let* ((resource
          (list "debugger" node-name))
         (args (list (cons "cmd" command))))
    (edts-rest-get-async resource args callback '())))

(defun edts-node-registeredp (node &optional no-error)
  "Return non-nil if NODE is registered with the EDTS server."
  (member node (edts-get-nodes no-error)))

(defun edts-get-nodes (&optional no-error)
  "Return all nodes registered with the EDTS server. If NO-ERROR is
non-nil, don't report an error if the request fails."
  (let (nodes
        (res (edts-rest-get '("nodes") nil)))
    (if (equal (assoc 'result res) '(result "200" "OK"))
        (cdr (assoc 'nodes (cdr (assoc 'body res))))
      (unless no-error
        (null (edts-log-error "Unexpected reply: %s"
                              (cdr (assoc 'result res))))))))

(defun edts--node-memberp (node nodes)
  (some #'(lambda (reg-node) (string-match (concat node "@") reg-node))))

(defun edts-node-name ()
  "Return the sname of current buffer's project node."
  (condition-case ex
      (eproject-attribute :node-sname)
    ('error (edts-shell-node-name))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Unit tests

(provide 'edts)
