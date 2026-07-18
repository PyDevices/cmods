set(CMOD_DIR ${CMAKE_CURRENT_LIST_DIR})

# Follow symlinks (-L): workspace modules are often cloned beside cmods and linked in.
# maxdepth 3 matches <cmods>/<module>/micropython.cmake (not this aggregator file).
# Exclude only hidden *children* of CMOD_DIR (e.g. cmods/.ucmods_*), so a slim
# tree used as USER_C_MODULES itself (CMOD_DIR=.ucmods_p4) still finds modules.
execute_process(
    COMMAND find -L ${CMOD_DIR} -mindepth 2 -maxdepth 3 -name micropython.cmake ! -path "${CMOD_DIR}/.*/*" -exec echo -n "{};" \;
    OUTPUT_VARIABLE CMODS
)

foreach(CMOD ${CMODS})
    message("Including file: ${CMOD}")
    include(${CMOD})
endforeach()
