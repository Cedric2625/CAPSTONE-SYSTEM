/// Reference lists for the vehicle registration form's searchable Model and
/// Color fields — real makes/models actually sold in the Philippine market,
/// grouped by body type, so the Model picker only ever shows options that
/// actually make sense for whichever Vehicle Type is selected.
///
/// "Other" is always the last entry in every list, purely so it's visible
/// as an option — [SearchableSelectField] (see widgets.dart) never enforces
/// picking from the list, so a model/color that's missing can already be
/// typed in directly. Selecting "Other" just clears the field to prompt a
/// fresh manual entry.
class VehicleCatalog {
  VehicleCatalog._();

  static const List<String> sedanModels = [
    'Toyota Vios',
    'Toyota Corolla Altis',
    'Toyota Camry',
    'Honda City',
    'Honda Civic',
    'Honda Accord',
    'Mitsubishi Mirage G4',
    'Mitsubishi Lancer',
    'Nissan Almera',
    'Nissan Sentra',
    'Hyundai Accent',
    'Hyundai Elantra',
    'Hyundai Reina',
    'Kia Soluto',
    'Kia Forte',
    'Suzuki Dzire',
    'Suzuki Ciaz',
    'Mazda2 Sedan',
    'Mazda3 Sedan',
    'Chevrolet Sail',
    'Ford Focus',
    'Subaru Impreza',
    'MG5',
    'MG6',
    'Geely Emgrand',
    'BYD Seal',
    'Other',
  ];

  static const List<String> suvModels = [
    'Toyota Fortuner',
    'Toyota RAV4',
    'Toyota Corolla Cross',
    'Toyota Rush',
    'Toyota Raize',
    'Honda CR-V',
    'Honda BR-V',
    'Honda HR-V',
    'Mitsubishi Montero Sport',
    'Mitsubishi Outlander',
    'Mitsubishi ASX',
    'Mitsubishi Xpander Cross',
    'Nissan Terra',
    'Nissan X-Trail',
    'Nissan Kicks',
    'Nissan Juke',
    'Ford Everest',
    'Ford Territory',
    'Ford EcoSport',
    'Hyundai Tucson',
    'Hyundai Santa Fe',
    'Hyundai Creta',
    'Hyundai Venue',
    'Hyundai Kona',
    'Kia Seltos',
    'Kia Sportage',
    'Kia Sorento',
    'Kia Stonic',
    'Suzuki Vitara',
    'Suzuki Jimny',
    'Suzuki XL7',
    'Mazda CX-3',
    'Mazda CX-30',
    'Mazda CX-5',
    'Mazda CX-8',
    'Chevrolet Trailblazer',
    'Chevrolet Trax',
    'Subaru XV',
    'Subaru Forester',
    'Subaru Evoltis',
    'Isuzu MU-X',
    'BYD Atto 3',
    'BYD Song Plus',
    'Geely Coolray',
    'Geely Azkarra',
    'MG ZS',
    'MG HS',
    'Chery Tiggo 7 Pro',
    'Chery Tiggo 8 Pro',
    'Haval H6',
    'Haval Jolion',
    'GAC GS3 Emzoom',
    'Jeep Wrangler',
    'Jeep Compass',
    'Volkswagen Tiguan Allspace',
    'Volkswagen T-Cross',
    'Land Rover Defender',
    'Land Rover Discovery Sport',
    'Peugeot 2008',
    'Peugeot 3008',
    'Other',
  ];

  static const List<String> hatchbackModels = [
    'Toyota Wigo',
    'Toyota Yaris',
    'Honda Brio',
    'Honda Jazz',
    'Mitsubishi Mirage',
    'Suzuki Swift',
    'Suzuki Celerio',
    'Suzuki Baleno',
    'Suzuki Ignis',
    'Suzuki S-Presso',
    'Hyundai i10',
    'Hyundai Accent Hatchback',
    'Kia Picanto',
    'Mazda2 Hatchback',
    'Nissan March',
    'Chevrolet Spark',
    'Chevrolet Aveo Hatchback',
    'MG3',
    'Volkswagen Up!',
    'Peugeot 208',
    'BYD Dolphin',
    'Geely GX3 Pro',
    'Other',
  ];

  /// The Vehicle Type choices. Four-wheel passenger and light-vehicle body
  /// styles only — motorcycles, tricycles, trucks, vans and public utility
  /// vehicles are outside the study's scope and are not offered.
  static const List<String> bodyTypes = [
    'Sedan',
    'Coupe',
    'Hatchback',
    'SUV',
    'Crossover',
    'MPV',
    'Wagon',
    'Convertible',
    'Pickup',
  ];

  /// Model options for the given Vehicle Type. Body styles without their own
  /// list (MPV, Pickup, Coupe, …) get every model above, de-duplicated, rather
  /// than being shown only Sedan models.
  static List<String> modelsFor(String vehicleType) {
    switch (vehicleType) {
      case 'SUV':
        return suvModels;
      case 'Hatchback':
        return hatchbackModels;
      case 'Sedan':
        return sedanModels;
      default:
        return {...sedanModels, ...hatchbackModels, ...suvModels}.toList();
    }
  }

  // Color availability doesn't meaningfully differ by body style —
  // manufacturers offer largely the same palette across their Sedan/SUV/
  // Hatchback lineups — so this is one shared list rather than three
  // near-identical ones that would just be redundant data to keep in sync.
  static const List<String> colors = [
    'White',
    'Pearl White',
    'Silver',
    'Gray',
    'Dark Gray',
    'Black',
    'Red',
    'Maroon',
    'Blue',
    'Dark Blue',
    'Light Blue',
    'Green',
    'Dark Green',
    'Yellow',
    'Orange',
    'Bronze',
    'Gold',
    'Brown',
    'Beige',
    'Purple',
    'Other',
  ];
}
