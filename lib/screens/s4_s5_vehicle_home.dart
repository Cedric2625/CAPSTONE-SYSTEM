import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../utils/app_theme.dart';
import '../services/app_state.dart';
import '../models/models.dart';
import '../utils/vehicle_catalog.dart';
import '../widgets/widgets.dart';
import '../widgets/document_photo.dart';

// ══════════════════════════════════════
// SCREEN 4: REGISTER VEHICLE
// ══════════════════════════════════════
/// The standalone "Add Vehicle" screen (Home and Profile). The form itself
/// lives in [VehicleFormSection], which the account registration page embeds
/// too, so the two can never drift apart.
class RegisterVehicleScreen extends StatelessWidget {
  const RegisterVehicleScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.vigiLiteBg,
        appBar: AppBar(
          backgroundColor: AppColors.vigiLiteBg,
          foregroundColor: AppColors.vigiLiteText,
          leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              tooltip: 'Back',
              onPressed: () => Navigator.pop(context)),
          title: const Text('Register Vehicle'),
        ),
        body: const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: VehicleFormSection(lite: true),
        ),
      );
}

class VehicleFormSection extends StatefulWidget {
  /// True inside the account registration page: the section has no save
  /// button of its own, and the page collects its entries with
  /// [VehicleFormSectionState.collectDraft] when the account is submitted.
  final bool embedded;

  /// True when reached standalone from Home/Profile ("Add Another Vehicle")
  /// — a VIGILINK Lite screen, so this renders the light navy/cyan palette
  /// instead of the dark one Register (where this is `embedded: true`)
  /// still uses.
  final bool lite;
  const VehicleFormSection(
      {super.key, this.embedded = false, this.lite = false});
  @override
  State<VehicleFormSection> createState() => VehicleFormSectionState();
}

class VehicleFormSectionState extends State<VehicleFormSection> {
  final _formKey = GlobalKey<FormState>();
  final _plate = TextEditingController();
  final _series = TextEditingController();
  final _color = TextEditingController();
  final _yearModel = TextEditingController();
  final _engineNumber = TextEditingController();
  final _chassisNumber = TextEditingController();
  final _deviceIdCtrl = TextEditingController();
  final _seriesFocus = FocusNode();
  final _colorFocus = FocusNode();
  String _type = 'Sedan';
  final double _geofence = 100;
  // Required: a photo of the vehicle's Official Receipt and of its Certificate
  // of Registration, each on its own.
  Uint8List? _orPhoto;
  Uint8List? _crPhoto;
  // True once a submit attempt found OR/CR still missing — highlights
  // whichever one(s) are still empty inline, in addition to the popup.
  bool _showDocErrors = false;

  @override
  void dispose() {
    _plate.dispose();
    _series.dispose();
    _color.dispose();
    _yearModel.dispose();
    _engineNumber.dispose();
    _chassisNumber.dispose();
    _deviceIdCtrl.dispose();
    _seriesFocus.dispose();
    _colorFocus.dispose();
    super.dispose();
  }

  bool _saving = false;

  /// Takes or chooses the OR or the CR photo. The photo is required and kept
  /// as it is — nothing is read from it, and every vehicle detail is typed in
  /// by the owner. The admin checks the documents when approving the
  /// registration.
  Future<void> _addDocPhoto({required bool isOr}) async {
    final source = await showImageSourceSheet(context,
        title:
            isOr ? 'Official Receipt (OR)' : 'Certificate of Registration (CR)',
        subtitle: 'The whole document must be in the photo and readable.');
    if (source == null) return;
    final r = await captureDocumentPhoto(source);
    if (!mounted) return;
    if (r.error != null) {
      await showErrorModal(context,
          title: 'Could Not Add Photo', message: r.error!);
      return;
    }
    if (r.bytes == null) return; // dismissed
    setState(() {
      if (isOr) {
        _orPhoto = r.bytes;
      } else {
        _crPhoto = r.bytes;
      }
    });
    showResultToast(context,
        message: isOr
            ? 'Official Receipt added.'
            : 'Certificate of Registration added.',
        success: true);
  }

  /// Validates the whole vehicle entry and returns it, or null after showing
  /// why it can't be used yet. Shared by the Add Vehicle save and the account
  /// registration submit.
  Future<VehicleDraft?> collectDraft() async {
    final formOk = _formKey.currentState!.validate();
    if (_orPhoto == null || _crPhoto == null) {
      setState(() => _showDocErrors = true);
      await showErrorModal(
        context,
        title: 'OR / CR Required',
        message:
            'Please add photos of both the Official Receipt (OR) and the Certificate of Registration (CR).',
        icon: Icons.description_outlined,
        color: AppColors.teal,
      );
      return null;
    }
    if (!formOk) return null;
    return VehicleDraft(
      plate: _plate.text.toUpperCase(),
      model: _series.text,
      color: _color.text,
      type: _type,
      yearModel: _yearModel.text,
      engineNumber: _engineNumber.text,
      chassisNumber: _chassisNumber.text,
      geofence: _geofence,
      orPhoto: _orPhoto!,
      crPhoto: _crPhoto!,
    );
  }

  Future<void> _save() async {
    final draft = await collectDraft();
    if (draft == null || !mounted) return;
    setState(() => _saving = true);
    showLoadingModal(context, message: 'Registering your vehicle…');
    final plate = draft.plate;
    final error = await context.read<AppState>().addVehicle(
        plate,
        draft.model,
        draft.color,
        draft.type,
        draft.yearModel,
        draft.engineNumber,
        draft.chassisNumber,
        draft.geofence,
        orPhoto: draft.orPhoto,
        crPhoto: draft.crPhoto);
    if (!mounted) return;
    Navigator.of(context).pop(); // the loading modal
    setState(() => _saving = false);
    if (error != null) {
      // Most notably: this plate is already registered to a different
      // account — nothing used to check that, so the same real-world
      // vehicle could end up "owned" by two different Gmail accounts at
      // once, with no way to tell whose theft report or geofence violation
      // was the real one.
      await showErrorModal(
        context,
        title: 'Vehicle Not Registered',
        message: error,
      );
      return;
    }
    await showSuccessModal(
      context,
      title: 'Vehicle Registered',
      message:
          '$plate was registered with its OR and CR and is now protected by VIGILINK.',
      icon: Icons.directions_car_filled,
    );
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/home');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final deviceId = widget.embedded
        ? 'Assigned when your account is created'
        : (state.currentUser?.deviceId ?? 'DEV-001');
    // A fresh TextEditingController was previously created inline in build()
    // for this read-only field — a new one on every rebuild, never disposed.
    // Reusing one controller field and just keeping its text in sync avoids
    // that leak.
    if (_deviceIdCtrl.text != deviceId) _deviceIdCtrl.text = deviceId;

    final lite = widget.lite;
    final cardColor = lite ? AppColors.vigiLiteCard : AppColors.vigiCard;
    final borderColor = lite ? AppColors.vigiLiteBorder : AppColors.vigiBorder;
    final textColor = lite ? AppColors.vigiLiteText : AppColors.vigiText;
    final text2Color = lite ? AppColors.vigiLiteText2 : AppColors.vigiText2;
    final text3Color = lite ? AppColors.vigiLiteText3 : AppColors.vigiText3;
    final inputColor = lite ? AppColors.vigiLiteInput : AppColors.vigiInput;
    final successColor =
        lite ? AppColors.vigiLiteSuccess : AppColors.vigiSuccess;
    final cyanColor = lite ? AppColors.vigiLiteCyan : AppColors.vigiCyan;
    final saveTextColor = lite ? AppColors.vigiLiteText : AppColors.vigiBg;

    return Form(
      key: _formKey,
      child: Column(
        children: [
          // OR/CR — both are required, and come first. The vehicle details
          // below are typed in by the owner.
          AppCard(
            color: cardColor,
            borderColor: borderColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('OR / CR Documents (Required)',
                    style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: textColor)),
                const SizedBox(height: 4),
                Text(
                    "Add a separate photo of the vehicle's Official Receipt and its Certificate of Registration. The plate, owner name and body type on them should be readable — once both are added, the plate number, vehicle type and year model below are filled in automatically.",
                    style: GoogleFonts.dmSans(
                        fontSize: 12, height: 1.4, color: text3Color)),
                const SizedBox(height: 12),
                DocumentPhotoCard(
                  title: 'OFFICIAL RECEIPT (OR)',
                  active: _orPhoto == null,
                  enabled: !_saving,
                  photo: _orPhoto,
                  hint:
                      'LTO Official Receipt: payment details, plate number and the receipt number.',
                  buttonLabel:
                      _orPhoto == null ? 'ADD PHOTO OF OR' : 'REPLACE OR PHOTO',
                  onCapture: () => _addDocPhoto(isOr: true),
                  showError: _showDocErrors,
                  dark: !lite,
                  lite: lite,
                ),
                const SizedBox(height: 12),
                DocumentPhotoCard(
                  title: 'CERTIFICATE OF REGISTRATION (CR)',
                  active: _crPhoto == null,
                  enabled: !_saving,
                  photo: _crPhoto,
                  hint:
                      'LTO Certificate of Registration: MV file no., plate, make, body type and registered owner.',
                  buttonLabel:
                      _crPhoto == null ? 'ADD PHOTO OF CR' : 'REPLACE CR PHOTO',
                  onCapture: () => _addDocPhoto(isOr: false),
                  showError: _showDocErrors,
                  dark: !lite,
                  lite: lite,
                ),
              ],
            ),
          ),
          // Vehicle info card
          AppCard(
            color: cardColor,
            borderColor: borderColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Vehicle Information',
                    style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: textColor)),
                const SizedBox(height: 14),
                AppTextField(
                  label: 'PLATE NUMBER',
                  hint: 'ABC-1234',
                  controller: _plate,
                  uppercase: true,
                  dark: !lite,
                  lite: lite,
                  validator: (v) => (v == null || v.isEmpty)
                      ? 'Plate number is required'
                      : null,
                ),
                // Vehicle Type and Color are each full-width, stacked —
                // not side-by-side — because the Color field's search
                // dropdown needs real width to be usable; squeezed into
                // half a row on a phone screen, its options list would
                // be too narrow to read comfortably.
                Text('VEHICLE TYPE',
                    style: GoogleFonts.dmMono(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: text3Color,
                        letterSpacing: 0.4)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  dropdownColor: cardColor,
                  style: GoogleFonts.dmSans(fontSize: 14, color: textColor),
                  decoration: InputDecoration(
                      filled: true,
                      fillColor: inputColor,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              BorderSide(color: borderColor, width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 13)),
                  items: VehicleCatalog.bodyTypes
                      .map((t) => DropdownMenuItem(
                          value: t,
                          child: Text(t,
                              style: GoogleFonts.dmSans(
                                  fontSize: 14, color: textColor))))
                      .toList(),
                  onChanged: (v) {
                    if (v == null || v == _type) return;
                    setState(() {
                      _type = v;
                      // The series list is different per type — a series
                      // picked under the old type may not even exist for
                      // the new one, so start fresh rather than silently
                      // keeping a mismatch.
                      _series.clear();
                    });
                  },
                ),
                const SizedBox(height: 14),
                SearchableSelectField(
                  label: 'COLOR',
                  hint: 'Search or type a color',
                  controller: _color,
                  focusNode: _colorFocus,
                  options: VehicleCatalog.colors,
                  dark: !lite,
                  lite: lite,
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Required' : null,
                ),
                SearchableSelectField(
                  label: 'SERIES',
                  hint: 'Search or type a series',
                  controller: _series,
                  focusNode: _seriesFocus,
                  options: VehicleCatalog.modelsFor(_type),
                  dark: !lite,
                  lite: lite,
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Series is required' : null,
                ),
                // Engine and chassis number — recommended by the Highway
                // Patrol Group (HPG) as what actually tells a single car
                // apart from every other one sharing its plate, make, or
                // color. Both are printed on the CR, right next to Series.
                AppTextField(
                  label: 'ENGINE NUMBER',
                  hint: 'e.g. K10BN5163463',
                  controller: _engineNumber,
                  uppercase: true,
                  dark: !lite,
                  lite: lite,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Engine number is required'
                      : null,
                ),
                AppTextField(
                  label: 'CHASSIS NUMBER',
                  hint: 'e.g. MA3FL41S2PA364088',
                  controller: _chassisNumber,
                  uppercase: true,
                  dark: !lite,
                  lite: lite,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Chassis number is required'
                      : null,
                ),
                AppTextField(
                  label: 'YEAR MODEL',
                  hint: '${DateTime.now().year}',
                  controller: _yearModel,
                  keyboardType: TextInputType.number,
                  dark: !lite,
                  lite: lite,
                  validator: (v) {
                    final t = v?.trim() ?? '';
                    if (t.isEmpty) return 'Year model is required';
                    final y = int.tryParse(t);
                    final nowYear = DateTime.now().year;
                    if (y == null || y < 1980 || y > nowYear + 1) {
                      return 'Enter a valid model year (e.g. $nowYear)';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
          // Device assignment card
          AppCard(
            color: cardColor,
            borderColor: borderColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Device Assignment',
                    style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: textColor)),
                const SizedBox(height: 14),
                AppTextField(
                    label: 'DEVICE ID (AUTO-FILLED)',
                    hint: '',
                    controller: _deviceIdCtrl,
                    readOnly: true,
                    dark: !lite,
                    lite: lite),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: successColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: successColor.withValues(alpha: 0.35))),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: successColor),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(
                              'This device will act as a relay node in the ad hoc network for theft alerts.',
                              style: GoogleFonts.dmSans(
                                  fontSize: 12, color: text2Color))),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!widget.embedded)
            PrimaryButton(
                label: 'SAVE VEHICLE',
                onTap: _save,
                loading: _saving,
                color: cyanColor,
                textColor: saveTextColor),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════
// SCREEN 5: HOME DASHBOARD
// ══════════════════════════════════════
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  final List<Widget> _pages = const [
    _HomeTab(),
    _MapTabPlaceholder(),
    _AlertsTabPlaceholder(),
    _ProfileTabPlaceholder(),
  ];

  /// Home is reached via `pushReplacement`/`pushNamedAndRemoveUntil` from
  /// Splash/Login, so once here there's nothing left before it in the
  /// navigator stack — the system back button would otherwise exit the app
  /// immediately on the very first press. Standard "press back again to
  /// exit" instead: the first press just records when, the second press
  /// within [_exitWindow] actually exits.
  static const _exitWindow = Duration(seconds: 2);
  DateTime? _lastBackPress;

  void _handleBackPress() {
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < _exitWindow) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.charcoal,
      duration: _exitWindow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: Text('Press back again to exit',
          style: GoogleFonts.dmSans(fontSize: 13, color: Colors.white)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBackPress();
      },
      child: Scaffold(
        body: IndexedStack(index: _tab, children: _pages),
        bottomNavigationBar: AppBottomNav(
          currentIndex: _tab,
          dark: true,
          onTap: (i) {
            // Home hosts the other 3 tabs itself (IndexedStack) — only Map/
            // Alerts/Profile actually navigate to a separate screen.
            if (i == 1) {
              Navigator.pushNamed(context, '/prox-map');
              return;
            }
            if (i == 2) {
              Navigator.pushNamed(context, '/alert-history');
              return;
            }
            if (i == 3) {
              Navigator.pushNamed(context, '/profile');
              return;
            }
            setState(() => _tab = i);
          },
        ),
      ),
    );
  }
}

// ─── HOME TAB CONTENT ───
class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.currentUser;
    final vehicles = state.myVehicles;
    final onlineNodes = state.nodes.where((n) => n.isOnline).toList();
    // Preview list is deliberately capped to a few rows for a compact
    // dashboard card; the stat tile below must reflect the true total,
    // not however many rows happen to be shown.
    // Devices that are found but still connecting are listed too (as
    // "Connecting…") — they used to be filtered out with everything that
    // wasn't yet connected, hiding whether discovery was working at all.
    final nodes = state.nodes.take(8).toList();
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning 👋'
        : hour < 17
            ? 'Good afternoon 👋'
            : 'Good evening 👋';

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      body: CustomScrollView(
        slivers: [
          // Header — flat Lite background, navy heading text.
          SliverToBoxAdapter(
            child: Container(
              color: AppColors.vigiLiteBg,
              padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 12,
                  left: 20,
                  right: 20,
                  bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(greeting,
                      style: GoogleFonts.dmSans(
                          fontSize: 13, color: AppColors.vigiLiteText2)),
                  const SizedBox(height: 2),
                  Text(user?.name ?? 'User',
                      style: GoogleFonts.dmSans(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteText)),
                  const SizedBox(height: 6),
                  const _ManilaClock(),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                        color: AppColors.vigiLiteCard,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.vigiLiteBorder)),
                    child: Row(
                      children: [
                        const SizedBox(width: 6),
                        Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: state.monitoringArmed
                                    ? AppColors.vigiLiteSuccess
                                    : AppColors.vigiLiteText3,
                                shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text(
                            state.monitoringArmed
                                ? 'Monitoring Armed'
                                : 'Monitoring Disabled',
                            style: GoogleFonts.dmSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.vigiLiteText)),
                        const Spacer(),
                        Switch(
                          value: state.monitoringArmed,
                          onChanged: (v) => state.toggleMonitoring(v),
                          activeThumbColor: AppColors.vigiLiteCyan,
                          activeTrackColor:
                              AppColors.vigiLiteCyan.withValues(alpha: 0.3),
                          inactiveThumbColor: AppColors.vigiLiteText3,
                          inactiveTrackColor: AppColors.vigiLiteBorder,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // GPS + Network status — required, honest status (never a faked GPS fix)
                  Row(
                    children: [
                      Expanded(
                        child: TapScale(
                          onTap: () => state.refreshGps(),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                                color: AppColors.vigiLiteCard,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: AppColors.vigiLiteBorder)),
                            child: Row(children: [
                              Icon(
                                  state.gpsStatus == GpsStatus.available
                                      ? Icons.gps_fixed
                                      : Icons.gps_not_fixed,
                                  size: 14,
                                  color: AppColors.vigiLiteText2),
                              const SizedBox(width: 6),
                              Expanded(
                                  child: Text(state.gpsStatus.label,
                                      style: GoogleFonts.dmSans(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.vigiLiteText2),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                              color: AppColors.vigiLiteCard,
                              borderRadius: BorderRadius.circular(10),
                              border:
                                  Border.all(color: AppColors.vigiLiteBorder)),
                          child: Row(children: [
                            Icon(
                                state.networkStatus == NetworkStatus.online ||
                                        state.networkStatus ==
                                            NetworkStatus.syncComplete
                                    ? Icons.wifi
                                    : Icons.wifi_off,
                                size: 14,
                                color: AppColors.vigiLiteText2),
                            const SizedBox(width: 6),
                            Expanded(
                                child: Text(state.networkStatus.label,
                                    style: GoogleFonts.dmMono(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.vigiLiteText2),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis)),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          SliverPadding(
            padding: const EdgeInsets.all(14),
            sliver: SliverList(
                delegate: SliverChildListDelegate([
              // Stats grid
              const SizedBox(height: 4),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.6,
                children: [
                  _StatTile(
                      value: '${state.activeAlerts.length}',
                      label: 'Active Alerts',
                      color: AppColors.vigiLiteCritical),
                  _StatTile(
                      value: '${vehicles.length}',
                      label: 'My Vehicles',
                      color: AppColors.vigiLiteInfo),
                  _StatTile(
                      value: '${onlineNodes.length}',
                      label: 'Nearby Nodes',
                      color: AppColors.vigiLiteWarning),
                  _StatTile(
                      value: '${state.totalRelayed}',
                      label: 'Alerts Relayed',
                      color: AppColors.vigiLiteSuccess),
                ],
              ),
              const SizedBox(height: 16),

              // My Vehicles
              const SectionLabel('MY VEHICLE', dark: true),
              if (vehicles.isEmpty)
                AppCard(
                  color: AppColors.vigiLiteCard,
                  borderColor: AppColors.vigiLiteBorder,
                  child: Column(children: [
                    const SizedBox(height: 8),
                    const Icon(Icons.directions_car_outlined,
                        size: 40, color: AppColors.vigiLiteText3),
                    const SizedBox(height: 8),
                    Text('No vehicles registered yet.',
                        style: GoogleFonts.dmSans(
                            fontSize: 13, color: AppColors.vigiLiteText3)),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.vigiLiteCyan,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            elevation: 0),
                        onPressed: () =>
                            Navigator.pushNamed(context, '/register-vehicle'),
                        child: Text('Register Vehicle',
                            style: GoogleFonts.dmSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.vigiLiteText)),
                      ),
                    ),
                  ]),
                )
              else
                ...vehicles.map((v) => VehicleCard(
                      vehicle: v,
                      dark: true,
                      onGeofence: () => Navigator.pushNamed(
                          context, '/geofence',
                          arguments: v),
                      onDeactivateGeofence: () async {
                        final ok = await showConfirmDialog(
                          context,
                          title: 'Turn Off Geofence for ${v.plate}?',
                          message:
                              'Monitoring stops until you turn it back on. The vehicle stays registered and its safe zone (${v.geofenceRadius.toInt()}m) is remembered, so reactivating it later won\'t need to be set up again.',
                          confirmLabel: 'Turn Off',
                          confirmColor: AppColors.amber,
                          icon: Icons.shield_moon_outlined,
                        );
                        if (!ok || !context.mounted) return;
                        // Second, final confirmation — guards against an
                        // accidental tap on the first dialog's confirm
                        // button before monitoring actually stops.
                        final reallySure = await showConfirmDialog(
                          context,
                          title: 'Are You Sure?',
                          message:
                              'Geofence monitoring for ${v.plate} will stop right away.',
                          confirmLabel: 'Yes, Turn Off',
                          cancelLabel: 'No, Keep It On',
                          confirmColor: AppColors.amber,
                          icon: Icons.shield_moon_outlined,
                        );
                        if (reallySure) {
                          await state.deactivateGeofence(v.id);
                          if (context.mounted) {
                            showResultToast(context,
                                message: 'Geofence turned off for ${v.plate}.',
                                success: true);
                          }
                        }
                      },
                      onRecover: v.status == VehicleStatus.stolen
                          ? () async {
                              final activeAlerts = state.myAlerts
                                  .where((a) =>
                                      a.vehicleId == v.id &&
                                      a.status == AlertStatus.active)
                                  .toList();
                              if (activeAlerts.isEmpty) {
                                // The vehicle is flagged stolen but there's no
                                // matching alert left to close (it failed to
                                // sync, or the report was interrupted) —
                                // without this fallback the owner would be
                                // stuck unable to ever report it stolen again.
                                final ok = await showConfirmDialog(
                                  context,
                                  title: 'No Theft Report Found',
                                  message:
                                      '${v.plate} is marked stolen, but no matching theft report was found on this device (this can happen after a sync problem). You can clear its stolen status directly instead. If it\'s still missing, report it stolen again afterward.',
                                  confirmLabel: 'Clear Stolen Status',
                                  confirmColor: AppColors.green,
                                  icon: Icons.build_circle_outlined,
                                );
                                if (ok) {
                                  await state.forceRecoverVehicle(v.id);
                                  if (context.mounted) {
                                    showResultToast(context,
                                        message:
                                            '${v.plate} stolen status cleared.',
                                        success: true);
                                  }
                                }
                                return;
                              }
                              // Recovery now requires a photo + remarks as
                              // proof, which needs its own form — this quick
                              // button can no longer just confirm inline.
                              Navigator.pushNamed(context, '/update-status',
                                  arguments: activeAlerts.first);
                            }
                          : null,
                      onRemove: () async {
                        final ok = await showConfirmDialog(
                          context,
                          title: 'Remove ${v.plate}?',
                          message:
                              'This will delete the vehicle and stop its geofence monitoring. This cannot be undone.',
                          confirmLabel: 'Remove',
                          icon: Icons.delete_outline,
                        );
                        if (!ok || !context.mounted) return;
                        // Second, final confirmation — a destructive,
                        // irreversible action (the vehicle and its geofence
                        // history are gone for good), so an accidental first
                        // tap still has one more chance to back out before
                        // anything is actually deleted.
                        final reallySure = await showConfirmDialog(
                          context,
                          title: 'Are You Sure?',
                          message:
                              '${v.plate} will be permanently deleted. This action cannot be reversed.',
                          confirmLabel: 'Yes, Remove Permanently',
                          cancelLabel: 'No, Keep It',
                          icon: Icons.delete_forever,
                        );
                        if (reallySure) {
                          state.removeVehicle(v.id);
                          if (context.mounted) {
                            showResultToast(context,
                                message: '${v.plate} removed.', success: true);
                          }
                        }
                      },
                    )),

              // Ad Hoc Mesh Status — real BLE/Wi-Fi Direct via Nearby Connections
              const SizedBox(height: 4),
              const SectionLabel('AD HOC NETWORK', dark: true),
              _MeshStatusCard(state: state),

              const SizedBox(height: 10),
              Row(
                children: [
                  Text('NEARBY DEVICES · BROADCAST RADIUS',
                      style: GoogleFonts.dmMono(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteText3,
                          letterSpacing: 0.4)),
                ],
              ),
              const SizedBox(height: 6),
              AppCard(
                color: AppColors.vigiLiteCard,
                borderColor: AppColors.vigiLiteBorder,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: nodes.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(children: [
                          Text('No participating devices are currently nearby.',
                              style: GoogleFonts.dmSans(
                                  fontSize: 13, color: AppColors.vigiLiteText3),
                              textAlign: TextAlign.center),
                          const SizedBox(height: 2),
                          Text(
                              'Any alert will remain stored and relay automatically once a device connects.',
                              style: GoogleFonts.dmSans(
                                  fontSize: 11, color: AppColors.vigiLiteText3),
                              textAlign: TextAlign.center),
                        ]),
                      )
                    : Column(
                        children:
                            nodes.map((n) => _NearbyNodeRow(node: n)).toList()),
              ),

              const SizedBox(height: 16),
              // REPORT STOLEN FAB
              TapScale(
                onTap: vehicles.isEmpty
                    ? () => showResultToast(context,
                        message: 'Please register a vehicle first.',
                        success: false)
                    : () => Navigator.pushNamed(context, '/report',
                        arguments: vehicles.first),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [
                      AppColors.vigiLiteCritical,
                      Color(0xFFB91C1C)
                    ]),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                          color:
                              AppColors.vigiLiteCritical.withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 8))
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('🚨', style: TextStyle(fontSize: 22)),
                      const SizedBox(width: 10),
                      Text('REPORT STOLEN',
                          style: GoogleFonts.dmSans(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ])),
          ),
        ],
      ),
    );
  }
}

// ─── LIVE MANILA CLOCK ───
// Ticks every second while the Home tab is open. Uses a fixed UTC+8 offset
// rather than the phone's own timezone/locale setting — the Philippines has
// no DST, so this is always correct regardless of the device's clock config.
class _ManilaClock extends StatefulWidget {
  const _ManilaClock();
  @override
  State<_ManilaClock> createState() => _ManilaClockState();
}

class _ManilaClockState extends State<_ManilaClock> {
  Timer? _timer;
  DateTime _now = _manilaNow();

  static DateTime _manilaNow() =>
      DateTime.now().toUtc().add(const Duration(hours: 8));

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = _manilaNow());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('EEE, MMM d, yyyy').format(_now);
    final timeStr = DateFormat('hh:mm:ss a').format(_now);
    return Row(children: [
      const Icon(Icons.schedule, size: 12, color: AppColors.vigiLiteText2),
      const SizedBox(width: 5),
      Text('$dateStr · $timeStr',
          style: GoogleFonts.dmMono(
              fontSize: 11,
              color: AppColors.vigiLiteText2,
              fontWeight: FontWeight.w600)),
    ]);
  }
}

class _StatTile extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  const _StatTile(
      {required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: AppColors.vigiLiteCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.vigiLiteBorder, width: 0.5)),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(value,
                  style: GoogleFonts.dmMono(
                      fontSize: 28, fontWeight: FontWeight.w700, color: color)),
              const SizedBox(height: 2),
              Text(label,
                  style: GoogleFonts.dmSans(
                      fontSize: 11,
                      color: AppColors.vigiLiteText3,
                      fontWeight: FontWeight.w500)),
            ]),
      );
}

class _MeshStatusCard extends StatefulWidget {
  final AppState state;
  const _MeshStatusCard({required this.state});

  @override
  State<_MeshStatusCard> createState() => _MeshStatusCardState();
}

class _MeshStatusCardState extends State<_MeshStatusCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();
  late int _lastSeenErrorSeq = widget.state.meshErrorSeq;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;

    // Surface mesh errors (connection rejected, request failed, malformed
    // payload, etc.) as a visible toast instead of leaving them buried in
    // System Logs where most users will never see them.
    if (state.meshErrorSeq != _lastSeenErrorSeq &&
        state.lastMeshError != null) {
      _lastSeenErrorSeq = state.meshErrorSeq;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showResultToast(context,
              message: state.lastMeshError!, success: false);
        }
      });
    }
    final scanning = state.meshPermissionsGranted &&
        state.meshActive &&
        state.connectedPeerCount == 0;
    final connected = state.connectedPeerCount > 0;
    final needsPermission = !state.meshPermissionsGranted;

    Color statusColor = AppColors.vigiLiteText3;
    if (connected) {
      statusColor = AppColors.vigiLiteSuccess;
    } else if (scanning) {
      statusColor = AppColors.vigiLiteInfo;
    } else if (needsPermission) {
      statusColor = AppColors.vigiLiteWarning;
    }

    return AppCard(
      color: AppColors.vigiLiteCard,
      borderColor: AppColors.vigiLiteBorder,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 34,
            height: 34,
            child: Stack(alignment: Alignment.center, children: [
              if (scanning)
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, __) => Container(
                    width: 34 * (0.5 + _pulse.value * 0.6),
                    height: 34 * (0.5 + _pulse.value * 0.6),
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.vigiLiteInfo
                            .withValues(alpha: (1 - _pulse.value) * 0.4)),
                  ),
                ),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle),
                child: Icon(
                    connected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_searching,
                    size: 13,
                    color: statusColor),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Real BLE / Wi-Fi Direct Mesh',
                    style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.vigiLiteText)),
                Text(state.meshStatusLabel,
                    style: GoogleFonts.dmMono(
                        fontSize: 11,
                        color: statusColor,
                        fontWeight: FontWeight.w600)),
                // Live radio state, so "0 nearby" can be told apart from "mesh
                // isn't actually running" without digging through System Logs.
                if (state.meshPermissionsGranted)
                  Text(
                    'Advertising ${state.meshAdvertising ? "ON" : "OFF"} · Scanning ${state.meshDiscovering ? "ON" : "OFF"} · Found ${state.discoveredPeerCount} · Connected ${state.connectedPeerCount}',
                    style: GoogleFonts.dmMono(
                        fontSize: 9.5, color: AppColors.vigiLiteText3),
                  ),
              ])),
        ]),
        if (needsPermission) ...[
          const SizedBox(height: 10),
          TapScale(
            onTap: () async {
              final granted = await state.requestMeshPermissions();
              if (context.mounted) {
                showResultToast(
                  context,
                  message: granted
                      ? 'Permissions granted — scanning for nearby devices.'
                      : 'Bluetooth/Location permission is required to find nearby devices.',
                  success: granted,
                );
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteWarning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.vigiLiteWarning.withValues(alpha: 0.4))),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.bluetooth,
                    size: 15, color: AppColors.vigiLiteWarning),
                const SizedBox(width: 6),
                Text('Grant Bluetooth & Location Permission',
                    style: GoogleFonts.dmSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.vigiLiteWarning)),
              ]),
            ),
          ),
        ],
        if (state.meshPermissionsGranted) ...[
          const SizedBox(height: 10),
          TapScale(
            onTap: () async {
              await state.restartMesh();
              if (context.mounted) {
                showResultToast(
                  context,
                  message: state.meshActive
                      ? 'Mesh restarted — scanning for nearby devices.'
                      : 'Could not restart the mesh. Make sure Bluetooth, Location (GPS) and Wi-Fi are all on (Wi-Fi doesn\'t need to be connected to a network).',
                  success: state.meshActive,
                );
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteInfo.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.vigiLiteInfo.withValues(alpha: 0.3))),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.refresh,
                    size: 15, color: AppColors.vigiLiteInfo),
                const SizedBox(width: 6),
                Text('Restart Scan',
                    style: GoogleFonts.dmSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.vigiLiteInfo)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

class _NearbyNodeRow extends StatelessWidget {
  final AdHocNode node;
  const _NearbyNodeRow({required this.node});

  @override
  Widget build(BuildContext context) {
    Color iconBg;
    String statusText;
    Color statusColor;

    if (node.viaInternet) {
      // A registered device signed in within range, located by its shared GPS.
      iconBg = AppColors.greenLight;
      statusText = 'Active';
      statusColor = AppColors.green;
    } else if (!node.isSimulated && !node.isOnline) {
      // real device discovered but connection still negotiating
      iconBg = AppColors.amberLight;
      statusText = 'Connecting…';
      statusColor = AppColors.amber;
    } else {
      switch (node.relayStatus) {
        case RelayStatus.received:
          iconBg = AppColors.orangeLight;
          statusText = 'Connected ✓';
          statusColor = AppColors.orange;
          break;
        case RelayStatus.relaying:
          iconBg = AppColors.yellowLight;
          statusText = 'Relaying…';
          statusColor = AppColors.yellow;
          break;
        case RelayStatus.pending:
          iconBg = AppColors.grayLight;
          statusText = 'Pending';
          statusColor = AppColors.gray;
      }
    }

    final distanceText =
        node.distance < 0 ? 'Nearby' : '${node.distance.toInt()}m away';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
          border: Border(
              bottom: BorderSide(color: AppColors.vigiLiteBorder, width: 0.6))),
      child: Row(
        children: [
          Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: Center(
                  child: Text(
                      node.viaInternet
                          ? '📍'
                          : (node.isSimulated ? '📱' : '📡'),
                      style: const TextStyle(fontSize: 16)))),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(node.name,
                    style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.vigiLiteText)),
                RichText(
                    text: TextSpan(children: [
                  TextSpan(
                      text: '$distanceText · ',
                      style: GoogleFonts.dmSans(
                          fontSize: 11, color: AppColors.vigiLiteText3)),
                  TextSpan(
                      text: '${node.connectionLabel} · $statusText',
                      style:
                          GoogleFonts.dmMono(fontSize: 10, color: statusColor)),
                ])),
              ])),
        ],
      ),
    );
  }
}

// Placeholders that redirect to named routes
class _MapTabPlaceholder extends StatelessWidget {
  const _MapTabPlaceholder();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _AlertsTabPlaceholder extends StatelessWidget {
  const _AlertsTabPlaceholder();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _ProfileTabPlaceholder extends StatelessWidget {
  const _ProfileTabPlaceholder();
  @override
  Widget build(BuildContext context) => const SizedBox();
}
