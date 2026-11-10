# Sourced by build.sh and rebuild_check. The shared LAN contract lives in packages/scan-link and is
# compiled straight into the app, so the Mac and iOS apps cannot drift apart.
SHARED_DIR=../../packages/scan-link/Sources/ScanLinkCore
SHARED_SOURCES="$SHARED_DIR/LanProtocol.swift $SHARED_DIR/LanEndpoint.swift $SHARED_DIR/LanClient.swift"
APP_SOURCES="$SHARED_SOURCES Mesh.swift UsdzConverter.swift PhotoReconstruction.swift PhotoQuality.swift LidarImport.swift MeshRender.swift ScanPackage.swift LanAdvertiser.swift PhoneReceiver.swift ThreeLayMacOS.swift"
