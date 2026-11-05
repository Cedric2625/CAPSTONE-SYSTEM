import 'package:flutter_test/flutter_test.dart';
import 'package:vehicleguard/utils/validators.dart';

void main() {
  test('validatePhMobile requires a valid Philippine mobile number', () {
    expect(validatePhMobile(''), 'Mobile number is required.');
    expect(validatePhMobile(null), 'Mobile number is required.');
    expect(validatePhMobile('12345'), isNotNull);
    expect(validatePhMobile('09171234567'), isNull);
    expect(validatePhMobile('+63 917 123 4567'), isNull);
    expect(validatePhMobile('0917-123-4567'), isNull);
    expect(validatePhMobile('09171234567x'), isNotNull);
    expect(validatePhMobile('091712345678'), isNotNull);
  });

  test('canonicalPhMobile treats formats of one number as equal', () {
    expect(canonicalPhMobile('+63 917 123 4567'), '09171234567');
    expect(canonicalPhMobile('0917-123-4567'), '09171234567');
    expect(canonicalPhMobile('09171234568') == canonicalPhMobile('09171234567'),
        isFalse);
  });

  test('normalizedPlate treats formats of one plate as equal', () {
    // The exact bug report this was added for: "GAS9817" and "GAS-9817"
    // registered as if they were two different vehicles.
    expect(normalizedPlate('GAS9817'), 'GAS9817');
    expect(normalizedPlate('GAS-9817'), 'GAS9817');
    expect(normalizedPlate('gas 9817'), 'GAS9817');
    expect(normalizedPlate('ABC-1234') == normalizedPlate('ABD-1234'), isFalse);
  });
}
