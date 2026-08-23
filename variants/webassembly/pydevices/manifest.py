# Keep the regular WebAssembly frozen modules and replace socket-based
# ``requests`` with the Fetch/Asyncify implementation supplied by this variant.
include("$(PORT_DIR)/variants/manifest.py")
