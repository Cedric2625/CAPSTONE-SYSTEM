allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Some older/unmaintained plugins (nearby_connections 3.3.1 is one of them)
// were published before AGP 7.3+ required every Android library module to
// declare a `namespace`. Rather than hand-editing that plugin's cached files
// (which would be silently undone on the next `flutter pub get` and
// wouldn't travel with this project to another machine), this backfills a
// missing namespace automatically at build time, reading it from the
// plugin's own AndroidManifest.xml `package` attribute — the same value
// Android's own "AGP Upgrade Assistant" would have migrated automatically.
// This only fills in a namespace where one is genuinely missing; modules
// that already declare one (including this app itself) are untouched.

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
