let
  # Identities
  nwmqpaMain = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGDdnrldIg416flniTapS18pv/IRwy6y03D+QmjF9euv";

  nwmqpaDerived = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIT3juohQ7S8lU/8T5PEk8peVdDx9IjZCZtWrI30fMij";

  mzlapqMain = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB9XyQ53ztHRg2u8gMTd1JN+WOeJ2WPe91rcc7gbzJNN";

  virtualbox-nwmqpa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHMUPPWoKGmRxJmQq7sz8li1ffBrqMLB633yJa2LaLwh";
  utm-nwmqpa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHMUPPWoKGmRxJmQq7sz8li1ffBrqMLB633yJa2LaLwh";

  # Groups
  nwmqpa = [
    nwmqpaMain
    nwmqpaDerived
  ];

  mzlapq = [
    mzlapqMain
  ];

  machines = [
    utm-nwmqpa
    virtualbox-nwmqpa
  ];

  users = nwmqpa ++ mzlapq;

  all = machines ++ users;

  k8s-control-plane = [
    utm-nwmqpa
  ];
in
{
  # User keys

  # Only this key need only the main key to be deciphered
  "nwmqpaDerivedSshKey.age".publicKeys = [ nwmqpaMain ];

  "nwmqpaPassword.age".publicKeys = [
    virtualbox-nwmqpa
    utm-nwmqpa
  ]
  ++ nwmqpa;

  # Only this key need only the main key to be deciphered
  "mzlapqDerivedSshKey.age".publicKeys = [ mzlapqMain ];

  # Machine keys
  "virtualbox-nwmqpa.age".publicKeys = [
    virtualbox-nwmqpa
  ]
  ++ users;

  "utm-nwmqpa.age".publicKeys = [
    utm-nwmqpa
  ]
  ++ users;

  "tailscaleKey.age".publicKeys = all;

  # CA keys
  "ca-root.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
  ];
  "ca-intermediate.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
  ];
  "ca-kubernetes.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
    virtualbox-nwmqpa
    utm-nwmqpa
  ];
  "ca-etcd.key.age".publicKeys = [
    nwmqpaMain
    mzlapqMain
    virtualbox-nwmqpa
    utm-nwmqpa
  ];
  # END_SECRETS
}
