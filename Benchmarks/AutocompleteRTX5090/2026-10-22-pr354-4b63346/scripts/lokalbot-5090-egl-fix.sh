set -eu
cat > /usr/share/glvnd/egl_vendor.d/10_nvidia.json <<'JSON'
{
  "file_format_version": "1.0.0",
  "ICD": { "library_path": "libEGL_nvidia.so.0" }
}
JSON
XDG_RUNTIME_DIR=/tmp/lokalbot-xdg vulkaninfo --summary > /workspace/pr354-validation/vulkan-summary-fixed.txt 2>&1
rg 'deviceName|driverInfo|deviceUUID' /workspace/pr354-validation/vulkan-summary-fixed.txt
