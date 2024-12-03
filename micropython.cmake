set(CMOD_DIR ${CMAKE_CURRENT_LIST_DIR})

execute_process(
    COMMAND find ${CMOD_DIR} -mindepth 2 -maxdepth 2 -name micropython.cmake -exec echo -n "{};" \;
    OUTPUT_VARIABLE CMODS
)

foreach(CMOD ${CMODS})
    message("Including file: ${CMOD}")
    include(${CMOD})
endforeach()
