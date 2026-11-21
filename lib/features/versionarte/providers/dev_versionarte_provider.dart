import 'package:package_info_plus/package_info_plus.dart';
import 'package:versionarte/versionarte.dart';

/// Development/no-op version check provider.
///
/// Always reports the running version as the latest so no update banners or
/// force-update screens appear during development.  Wire this in [setupLocator]
/// for both debug and, if no real provider is configured, any mode.
///
/// To activate real remote checks in a future phase, swap this for a
/// production [VersionarteProvider] implementation without touching versionarte
/// itself.
class DevVersionarteProvider extends VersionarteProvider {
  const DevVersionarteProvider();

  @override
  Future<DistributionManifest?> getDistributionManifest() async {
    final PackageInfo info = await Versionarte.packageInfo;
    final String current = info.version;

    final PlatformDistributionInfo distribution = PlatformDistributionInfo(
      downloadUrl: null,
      version: VersionDetails(minimum: current, latest: current),
      status: StatusDetails(
        active: true,
        message: const <String, String>{},
      ),
    );

    return DistributionManifest(
      android: distribution,
      iOS: distribution,
    );
  }
}
