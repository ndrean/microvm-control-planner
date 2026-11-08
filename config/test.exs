import Config

config :logger, level: :warning

config :fc_ex_cp,
  start_control_plane: false,
  vm_module: FcExCp.VMMock,
  desired_vms_config: nil,
  mock_delay: false
