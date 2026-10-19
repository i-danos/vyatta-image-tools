TEST_EXTENSIONS = .sh .pl
SHUNIT2_LOG_COMPILER = sh
PL_LOG_COMPILER = env vyatta_sbindir=../scripts $(PERL)
AM_PL_LOG_FLAGS = -w

TESTS = postinstall.vyatta-misc.sh
TESTS += vyatta-install-image.functions.sh
TESTS += install-image-copy-failure.sh
TESTS += install-image-fault-injection.sh
TESTS += sig-chain-heuristic.sh
TESTS += admin-password-hash.sh
TESTS += vyatta-live-image.sh
TESTS += vyatta_live.pl
TESTS += preinstall.virtualization.sh
TESTS += vyatta-create-partition.functions.sh
TESTS += vyatta-multiple-partition.functions.sh
