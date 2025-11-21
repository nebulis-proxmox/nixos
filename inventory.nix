{
  config,
  lib,
  ...
}:
{
  config.inventory = {
    hosts = {
      virtualbox-nwmqpa = {
        users.enableUsers = [
          "nwmqpa"
        ];
      };
    };
  };
}
