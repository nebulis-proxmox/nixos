let
  # Identities
  nwmqpaMain = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGDdnrldIg416flniTapS18pv/IRwy6y03D+QmjF9euv";
  nwmqpaDerived = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIT3juohQ7S8lU/8T5PEk8peVdDx9IjZCZtWrI30fMij";

  mzlapqMain = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB9XyQ53ztHRg2u8gMTd1JN+WOeJ2WPe91rcc7gbzJNN";

  nwmqpa = [
    nwmqpaMain
    nwmqpaDerived
  ];

  mzlapq = [
    mzlapqMain
  ];

  virtualbox-nwmqpa = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHMUPPWoKGmRxJmQq7sz8li1ffBrqMLB633yJa2LaLwh";

  all = [
    nwmqpaMain
    nwmqpaDerived
    mzlapqMain
    virtualbox-nwmqpa
  ];
in
{
  # Secrets

  # Only this key need only the main key to be deciphered
  "nwmqpaDerivedSshKey.age".publicKeys = [ nwmqpaMain ];
  "nwmqpaPassword.age".publicKeys = [ virtualbox-nwmqpa ] ++ nwmqpa;

  "mzlapqDerivedSshKey.age".publicKeys = [ mzlapqMain ];

  "virtualbox-nwmqpa.age".publicKeys = [
    virtualbox-nwmqpa
  ]
  ++ nwmqpa
  ++ mzlapq;
}
