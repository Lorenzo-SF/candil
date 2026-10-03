# Logger level for the application.
#
# `:warning`, not `:debug`, because the only consumer of this application's
# stdout is the person holding the terminal or a script holding a pipe. A
# dependency's `Logger.debug` on the way up is noise to both, and in the case
# of `candil doctor --json` it made the output unparseable: the JSON was
# preceded by a line from `Arrea`, so `| jq` failed on it.
#
# This lives in config and not in `Candil.CLI.main/1` because a runtime call
# arrives too late — by then the applications have booted and already logged.
import Config

config :logger, level: :warning
