(module conjure.client.javascript.stdio
  {autoload {a conjure.aniseed.core
             extract conjure.extract
             str conjure.aniseed.string
             nvim conjure.aniseed.nvim
             stdio conjure.remote.stdio
             config conjure.config
             text conjure.text
             mapping conjure.mapping
             client conjure.client
             log conjure.log
             ts conjure.tree-sitter}
   require-macros [conjure.macros]})

(config.merge
  {:client
   {:javascript
    {:stdio
     {:mapping {:start "cs"
                :stop "cS"
                :interrupt "ei"}
      :command "node -i"
      :prompt-pattern "> "
      :delay-stderr-ms 10}}}})

(def- cfg (config.get-in-fn [:client :javascript :stdio]))

(defonce- state (client.new-state #(do {:repl nil})))

(def buf-suffix ".js")
(def comment-prefix "// ")

(defn- with-repl-or-warn [f opts]
  (let [repl (state :repl)]
    (if repl
      (f repl)
      (log.append [(.. comment-prefix "No REPL running")
                   (.. comment-prefix
                       "Start REPL with "
                       (config.get-in [:mapping :prefix])
                       (cfg [:mapping :start]))]))))


; Returns whether a given expression node is an assignment expression
; An assignment expression seems to be a weird case where it does not actually
; evaluate to anything so it seems more like a statement
(defn is-assignment?
  [node]
  (and (= (node:child_count) 1)
       (let [child (node:child 0)]
         (= (child:type) "assignment"))))

(defn is-expression?
  [node]
  (and (= "expression_statement" (node:type))
       (not (is-assignment? node))))

; Returns whether the string passed in is a simple javascript
; expression or something more complicated. If it is an expression,
; it can be passed to the REPL as is.
; Otherwise, we evaluate it as a multiline string using "eval". This is a simple
; way for us to not worry about extra or missing newlines in the middle of the code
; we are trying to evaluate at the REPL.
;
; For example, this javascript code:
;   for i in range(5):
;       print(i)
;   def foo():
;       print("bar")
; while valid javascript code, would not work in the REPL because the REPL expects 2 newlines
; after the for loop body.
;
; In addition, this javascript code:
;   for i in range(5):
;       print(i)
;
;       print(i)
; while also valid javascript code, would not work in the REPL because the REPL thinks the for loop
; body is over after the first "print(i)" (because it is followed by 2 newlines).
;
; Sending statements like these as a multiline string to javascript's eval seems to be a decent workaround
; for this. Another option that I have seen used in some other similar projects is sending the statement
; as a "bracketed paste" (https://cirw.in/blog/bracketed-paste) so the REPL treats the input as if it were
; "pasted", but I couldn't get this working.
(defn str-is-javascript-expr?
  [s]
  (let [parser (vim.treesitter.get_string_parser s "javascript")
        result (parser:parse)
        tree (a.get result 1)
        root (tree:root)]
    (and (= 1 (root:child_count))
         (is-expression? (root:child 0)))))


(defn- prep-code [s]
  (.. s "\n"))

; If, after pressing newline, the javascript interpreter expects more
; input from you (as is the case after the first line of an if branch or for loop)
; the javascript interpreter will output "..." to show that it is waiting for more input.
; We want to detect these lines and ignore them.
; Note: This is check will yield some false positives. For example if a user evaluates
;   print("... <-- check out those dots")
; the output will be flagged as one of these special "dots" lines. This could probably
; be smarter, but will work for most normal cases for now.
(defn- is-dots? [s]
  (= (string.sub s 1 3) "..."))

(defn format-msg [msg]
  (->> (str.split msg "\n")
       (a.filter #(~= "" $1))
       (a.filter #(not (is-dots? $1)))))

(defn- get-console-output-msgs [msgs]
  (->> (a.butlast msgs)
       (a.map #(.. comment-prefix "(out) " $1))))

(defn- get-expression-result [msgs]
  (let [result (a.last msgs)]
    (if
      (or (a.nil? result) (is-dots? result))
      nil
      result)))

(defn unbatch [msgs]
  (->> msgs
       (a.map #(or (a.get $1 :out) (a.get $1 :err)))
       (str.join "")))

(defn- log-repl-output [msgs]
  (let [msgs (-> msgs unbatch format-msg)
        console-output-msgs (get-console-output-msgs msgs)
        cmd-result (get-expression-result msgs)]
    (when (not (a.empty? console-output-msgs))
      (log.append console-output-msgs))
    (when cmd-result
      (log.append [cmd-result]))))

(defn eval-str [opts]
  (with-repl-or-warn
    (fn [repl]
      (repl.send
        (prep-code opts.code)
        (fn [msgs]
          (log-repl-output msgs)
          (when opts.on-result
            (let [msgs (-> msgs unbatch format-msg)
                  cmd-result (get-expression-result msgs)]
              (opts.on-result cmd-result))))
        {:batch? true}))))

(defn eval-file [opts]
  (eval-str (a.assoc opts :code (a.slurp opts.file-path))))

(defn get-help [code]
  (str.join "" ["help(" (str.trim code) ")"]))

(defn doc-str [opts]
  (when (str-is-javascript-expr? opts.code)
    (eval-str (a.assoc opts :code (get-help opts.code)))))

(defn- display-repl-status [status]
  (let [repl (state :repl)]
    (when repl
      (log.append
        [(.. comment-prefix (a.pr-str (a.get-in repl [:opts :cmd])) " (" status ")")]
        {:break? true}))))

(defn stop []
  (let [repl (state :repl)]
    (when repl
      (repl.destroy)
      (display-repl-status :stopped)
      (a.assoc (state) :repl nil))))

(defn start []
  (if (state :repl)
    (log.append [(.. comment-prefix "Can't start, REPL is already running.")
                 (.. comment-prefix "Stop the REPL with "
                     (config.get-in [:mapping :prefix])
                     (cfg [:mapping :stop]))]
                {:break? true})
    (if (not (pcall #(vim.treesitter.require_language "javascript")))
      (log.append [(.. comment-prefix "(error) The javascript client requires a javascript treesitter parser in order to function.")
                   (.. comment-prefix "(error) See https://github.com/nvim-treesitter/nvim-treesitter")
                   (.. comment-prefix "(error) for installation instructions.")])
      (a.assoc
        (state) :repl
        (stdio.start
          {:prompt-pattern (cfg [:prompt-pattern])
           :cmd (cfg [:command])
           :delay-stderr-ms (cfg [:delay-stderr-ms])

           :on-success
           (fn []
             (display-repl-status :started
              (with-repl-or-warn
               (fn [repl]
                 (repl.send
                   (prep-code "")
                   (fn [msgs] nil)
                   nil)))))

           :on-error
           (fn [err]
             (display-repl-status err))

           :on-exit
           (fn [code signal]
             (when (and (= :number (type code)) (> code 0))
               (log.append [(.. comment-prefix "process exited with code " code)]))
             (when (and (= :number (type signal)) (> signal 0))
               (log.append [(.. comment-prefix "process exited with signal " signal)]))
             (stop))

           :on-stray-output
           (fn [msg]
             (log.dbg (-> [msg] unbatch format-msg) {:join-first? true}))})))))

(defn on-load []
  (start))

(defn on-exit []
  (stop))

(defn interrupt []
  (with-repl-or-warn
    (fn [repl]
      (let [uv vim.loop]
        (uv.kill repl.pid uv.constants.SIGINT)))))

(defn on-filetype []
  (mapping.buf
    :JavascriptStart (cfg [:mapping :start])
    start
    {:desc "Start the javascript REPL"})

  (mapping.buf
    :JavascriptStop (cfg [:mapping :stop])
    stop
    {:desc "Stop the javascript REPL"})

  (mapping.buf
    :JavascriptInterrupt (cfg [:mapping :interrupt])
    interrupt
    {:desc "Interrupt the current evaluation"}))

