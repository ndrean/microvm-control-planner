import Config

config :exqlite, force_build: true

config :fc_ex_cp, :firecracker, FcExCp.Firecracker.Mock

import_config "#{config_env()}.exs"
