import 'dart:math';

/// One agency's emergency contact number(s) for a locality. A few agencies
/// have more than one number — most often because the source lists a
/// separate number per mobile network (Smart/Globe/TNT/TM) so the right one
/// can be dialed regardless of which carrier the caller is on.
class HotlineEntry {
  final String agency;
  final List<String> numbers;

  /// True for a barangay-level contact. The UI groups these under a
  /// collapsible section beneath the municipal/city-level numbers, so a
  /// locality with many barangays (e.g. Alegria) doesn't bury its main
  /// police/fire/DRRMO numbers under a long list.
  final bool isBarangay;
  const HotlineEntry(this.agency, this.numbers, {this.isBarangay = false});
}

/// Emergency hotlines for one Caraga Region locality, keyed to the
/// approximate coordinates of its town/city proper. Those coordinates are
/// used only to find the CLOSEST listed locality to a reported GPS
/// position — a best-effort "which town is this nearest to" match, not a
/// precise jurisdiction boundary.
class HotlineArea {
  final String name;
  final double lat;
  final double lng;
  final List<HotlineEntry> entries;
  const HotlineArea({
    required this.name,
    required this.lat,
    required this.lng,
    required this.entries,
  });
}

/// Every locality covered, each with the hotline numbers found for it.
/// Numbers are kept exactly as sourced (only whitespace trimmed) rather than
/// reformatted, so nothing here is altered from the original listing.
const List<HotlineArea> caragaHotlineAreas = [
  HotlineArea(name: 'Butuan City', lat: 8.9475, lng: 125.5406, entries: [
    HotlineEntry('Butuan City Police Office (BCPO)', ['09985987292']),
    HotlineEntry('BCPO — Police Station 1', ['09075501738']),
    HotlineEntry('BCPO — Police Station 2', ['09985687295']),
    HotlineEntry('BCPO — Police Station 3', ['09985987297']),
    HotlineEntry('BCPO — Police Station 4', ['09985987299']),
    HotlineEntry('BCPO — Police Station 5', ['09985987301']),
    HotlineEntry('BCPO — Police Station 6', ['09641324263']),
    HotlineEntry('BCPO Mobile Force Company (BCMFC)', ['09302970041']),
    HotlineEntry('Highway Patrol Group (HPG) — Butuan City', ['09122667014']),
    HotlineEntry(
        'Butuan City DRRMO', ['09217687287 (Smart)', '09561333998 (Globe)']),
    HotlineEntry('Bureau of Fire Protection (BFP) Butuan', ['0917 772 6300']),
    HotlineEntry('Butuan City Fire Station', [
      '0931 721 8876 (TNT)',
      '0955 214 8542 (TM)',
      '225 0500 (Landline)',
      '342 8217 (Landline)',
    ]),
  ]),
  HotlineArea(
      name: 'R.T. Romualdez (RTR), Agusan del Norte',
      lat: 9.1700,
      lng: 125.5340,
      entries: [
        HotlineEntry('MDRRMO — RTR', ['09297734427', '09496098278']),
        HotlineEntry('BFP — RTR', ['09275185156 (TM)']),
      ]),
  HotlineArea(name: 'Cabadbaran City', lat: 9.1234, lng: 125.5342, entries: [
    HotlineEntry('PDRRMO — Agusan del Norte', ['09510955215']),
    HotlineEntry('Cabadbaran City DRRMO',
        ['09988668771 (Smart)', '09171375977 (Globe)']),
    HotlineEntry('PNP — Cabadbaran City', ['09985987278', '09173058804']),
  ]),
  HotlineArea(
      name: 'Santiago, Agusan del Norte',
      lat: 9.1148,
      lng: 125.4983,
      entries: [
        HotlineEntry('MDRRMO — Santiago', ['09178954289']),
        HotlineEntry('BFP — Santiago', ['0931-721-8883 (TNT)']),
      ]),
  HotlineArea(
      name: 'Jabonga, Agusan del Norte',
      lat: 9.3330,
      lng: 125.5168,
      entries: [
        HotlineEntry(
            'MDRRMO / Emergency Response Team — Jabonga', ['09383141162']),
        HotlineEntry('PNP — Jabonga', ['09985987280']),
        HotlineEntry('BFP — Jabonga', ['09317218878']),
        HotlineEntry('Philippine Coast Guard — Jabonga', ['09516365158']),
        HotlineEntry('Municipal Health Office — Jabonga', ['09627025669']),
      ]),
  HotlineArea(
      name: 'Kitcharao, Agusan del Norte',
      lat: 9.3833,
      lng: 125.5667,
      entries: [
        HotlineEntry('MDRRMO — Kitcharao', ['09213484261']),
        HotlineEntry(
            'Municipal Police Station (MPS) — Kitcharao', ['09300862395']),
        HotlineEntry('BFP — Kitcharao', ['09317218879']),
      ]),
  HotlineArea(
      name: 'Alegria, Surigao del Norte',
      lat: 9.6625,
      lng: 125.5253,
      entries: [
        HotlineEntry('MDRRMO — Alegria', ['09813442860']),
        HotlineEntry(
            'Municipal Health Office (MHO) — Alegria', ['09465062346']),
        HotlineEntry('MSWDO — Alegria', ['09129843874']),
        HotlineEntry('BFP — Alegria', ['09317218772']),
        HotlineEntry('PNP — Alegria', ['09985987330']),
        HotlineEntry('Barangay DRRMO — Ouano', ['09925642365'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Pongtud', ['09109876439'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Anahaw', ['09501781406'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Ombong', ['09103210253'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Camp Edward', ['09450740665'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Poblacion', ['09934216258'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — San Pedro', ['09266246014'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — San Juan', ['09850382757'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Alipao', ['09927792802'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Ferlda', ['09816163034'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Gamuton', ['09189673841'],
            isBarangay: true),
        HotlineEntry('Barangay DRRMO — Budlingin', ['09678043415'],
            isBarangay: true),
      ]),
  HotlineArea(
      name: 'Mainit, Surigao del Norte',
      lat: 9.5700,
      lng: 125.5050,
      entries: [
        HotlineEntry('BFP — Mainit', ['09317218781']),
        HotlineEntry(
            'Municipal Police Station (MPS) — Mainit', ['09985987340']),
        HotlineEntry('Rural Health Unit (RHU) — Mainit',
            ['09489592565', '090994733799']),
        HotlineEntry('MDRRMO — Mainit', ['09635390815']),
      ]),
  HotlineArea(name: 'Surigao City', lat: 9.7873, lng: 125.4921, entries: [
    HotlineEntry('Emergency Response Services — Surigao City',
        ['09294209511', '09709676338']),
    HotlineEntry('PDRRMO — Surigao del Norte', ['09624255720']),
    HotlineEntry(
        'BFP — Surigao City', ['09317218790', '09552148510', '09262260360']),
    HotlineEntry('Philippine Coast Guard — Surigao del Norte (SDN)',
        ['09518070127', '09161853901']),
    HotlineEntry(
        'Surigao City Police Station (SCPS)', ['09985398568', '09985987328']),
    HotlineEntry('Philippine Coast Guard — Surigao City', ['09850460621']),
    HotlineEntry('CDRRMO — Surigao City', ['09515176419']),
    HotlineEntry('Philippine Coast Guard — Lipata', ['09664214813']),
  ]),
];

/// Haversine great-circle distance in meters — kept local to this file (no
/// geolocator import) so the hotline data has no dependency of its own.
double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLng = (lng2 - lng1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) *
          cos(lat2 * pi / 180) *
          sin(dLng / 2) *
          sin(dLng / 2);
  return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a));
}

/// The listed locality whose town/city center is closest to [lat]/[lng] — a
/// best-effort "which area is this nearest to" match, not a precise
/// jurisdiction lookup. Used to show the right authorities for wherever a
/// theft was reported.
HotlineArea nearestHotlineArea(double lat, double lng) {
  var best = caragaHotlineAreas.first;
  var bestDistance = _distanceMeters(lat, lng, best.lat, best.lng);
  for (final area in caragaHotlineAreas.skip(1)) {
    final distance = _distanceMeters(lat, lng, area.lat, area.lng);
    if (distance < bestDistance) {
      best = area;
      bestDistance = distance;
    }
  }
  return best;
}
