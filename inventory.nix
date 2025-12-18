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
      utm-nwmqpa = {
        users.enableUsers = [
          "nwmqpa"
        ];
      };
    };
  };
}
