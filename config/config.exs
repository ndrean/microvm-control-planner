import Config

config :exqlite, force_build: true

config :fc_ex_cp,
  vm_module: FcExCp.VM,
  firecracker_impl: FcExCp.Firecracker.Mock

import_config "#{config_env()}.exs"
