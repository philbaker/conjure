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


(defn- prep-code [s]
  (.. s "\n"))

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

