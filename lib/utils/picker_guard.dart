/// True while a camera/gallery picker THIS app itself opened is in front —
/// covers every `ImagePicker.pickImage()` call site in the app (theft report
/// evidence photos, OR/CR, driver's license, recovery photo, sighting photo,
/// profile photo). Set right before the picker opens, cleared right after it
/// returns (in a `finally`, so a thrown error or a cancelled pick never
/// leaves it stuck `true`).
///
/// Android reports the app as "paused" the instant the system camera/gallery
/// activity comes to the front — indistinguishable, from `didChangeAppLifecycleState`
/// alone, from the user actually switching to a different app. AppState's
/// background-mesh hand-off timer checks this flag before acting, so opening
/// the camera mid-form (e.g. while submitting a theft report) never triggers
/// a mesh reconnect.
bool isPickerOpen = false;
