{ mkDerivation, aeson, aeson-pretty, base, bytestring
, case-insensitive, conduit, containers, directory, feed, filepath
, hashable, hslogger, html-entity, http-client, irc-conduit, lens
, lib, lrucache, network, optparse-applicative, random, safe, text
, time, timerep, unordered-containers, wreq
}:
mkDerivation {
  pname = "brockman";
  version = "5.3.0";
  src = ./.;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    aeson aeson-pretty base bytestring case-insensitive conduit
    containers directory feed filepath hashable hslogger html-entity
    http-client irc-conduit lens lrucache network optparse-applicative
    random safe text time timerep unordered-containers wreq
  ];
  license = lib.licenses.mit;
  mainProgram = "brockman";
}
