# The stock SPIRAM_OCT variant, plus flash auto-suspend.
#
# The append has to come LAST: kconfgen takes the last assignment in
# SDKCONFIG_DEFAULTS, so a fragment listed before the port's own is silently
# overridden. That ordering is the whole trick, and getting it wrong looks
# like a build that succeeds with the feature simply absent (cmods#29).
include(${MICROPY_PORT_DIR}/boards/ESP32_GENERIC_S3/mpconfigvariant_SPIRAM_OCT.cmake)
list(APPEND SDKCONFIG_DEFAULTS ${CMAKE_CURRENT_LIST_DIR}/sdkconfig.autosuspend)
