import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val dartDefines = (project.findProperty("dart-defines") as String?)
    ?.split(",")
    ?.map { String(Base64.getDecoder().decode(it)) }
    .orEmpty()
val playStore = "PLAY_STORE=true" in dartDefines

val uploadKey = listOfNotNull(System.getenv("ZERK_PLAY_UPLOAD_KEY")?.let(::file), rootProject.file("key.properties"))
    .firstOrNull { it.isFile }
    ?.let { f -> Properties().apply { f.inputStream().use(::load) } }

// Optional single-ABI build, used by CI to ship a 32-bit fallback APK for old
// TV boxes:
//   flutter build apk --target-platform android-arm -Pzerk.abi=armeabi-v7a
// --target-platform alone is not enough: it only picks the AOT snapshot, and
// the Flutter plugin still puts every supported ABI into the APK, which leaves
// arm64-v8a without a libapp.so and makes the APK crash on 64-bit devices.
// abiFilters set here win over the plugin's defaults.
val abiFilter = (project.findProperty("zerk.abi") as String?)
    ?.split(',', ';')
    ?.map { it.trim() }
    ?.filter { it.isNotEmpty() }
    .orEmpty()

android {
    namespace = "cloud.zerk.play"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = if (playStore) "com.zerkplay" else "cloud.zerk.play"
        // Android 6.0. The Flutter engine itself declares minSdk 24 (Flutter
        // 3.35 raised it from 21), so this is opt-in territory: see the
        // tools:overrideLibrary note in AndroidManifest.xml. Every native
        // dependency we ship (media3 1.9.4, the Jellyfin ffmpeg decoder,
        // tvprovider) is fine at 23 - the engine is the only one above it.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (abiFilter.isNotEmpty()) {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(abiFilter)
            }
        }
    }

    signingConfigs {
        if (uploadKey != null) {
            create("upload") {
                storeFile = file(uploadKey.getProperty("storeFile"))
                storePassword = uploadKey.getProperty("storePassword")
                keyAlias = uploadKey.getProperty("keyAlias")
                keyPassword = uploadKey.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Every GitHub build must be signed with the same key, otherwise
            // Android refuses to install one over the other ("signatures do
            // not match"). The runner's debug keystore is generated per job
            // with a random key, so falling back to it made each APK unique.
            // android/key.properties points at the committed keystore, so both
            // the test builds and the stable release share one identity.
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
            proguardFiles("proguard-rules.pro")
        }
    }

    if (playStore) {
        sourceSets.getByName("release").manifest.srcFile("src/play/AndroidManifest.xml")
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

val media3Version = "1.9.4"

dependencies {
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-ui:$media3Version")
    implementation("org.jellyfin.media3:media3-ffmpeg-decoder:1.9.0+1")
    implementation("androidx.tvprovider:tvprovider:1.0.0")
}
