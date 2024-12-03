import os

# Find all manifest.py files in immediate subdirectories of the current directory
# and include them.
for dir in os.listdir("."):
    if os.path.exists(dir + "/manifest.py"):
        print(f"Including {dir}/manifest.py")
        include(dir + "/manifest.py")


try:
    include("$(BOARD_DIR)/manifest.py")
except Exception:
    try:
        include("$(PORT_DIR)/boards/manifest.py")
    except Exception:
        try:
            include("$(PORT_DIR)/variants/standard/manifest.py")
        except Exception:
            try:
                include("$(PORT_DIR)/variants/manifest.py")
            except Exception:
                pass
