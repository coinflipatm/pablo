import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Pull a value out of --dart-define so one flag feeds both Dart and the manifest.
fun findDartDefineValue(key: String): String? {
    val encodedDartDefines = project.properties["dart-defines"] as? String ?: ""
    val defines = encodedDartDefines.split(",").mapNotNull {
        try {
            val decoded = String(Base64.getDecoder().decode(it), Charsets.UTF_8).split("=", limit = 2)
            if (decoded.size == 2) decoded[0] to decoded[1] else null
        } catch (e: IllegalArgumentException) {
            null
        }
    }.toMap()
    return defines[key]
}

// Optional release signing. CI writes android/key.properties + android/app/upload.jks
// from repository secrets; local builds without them fall back to the debug key.
val keyProps = Properties()
val keyPropsFile = rootProject.file("key.properties")
val hasReleaseKey = keyPropsFile.exists()
if (hasReleaseKey) {
    keyPropsFile.inputStream().use { keyProps.load(it) }
}

android {
    namespace = "cv.towtruck.pablo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    androidResources {
        localeFilters.add("en")
    }

    defaultConfig {
        applicationId = "cv.towtruck.pablo"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true

        val mapsApiKey = System.getenv("MAPS_API_KEY") ?: findDartDefineValue("MAPS_API_KEY") ?: ""
        manifestPlaceholders["MAPS_API_KEY"] = mapsApiKey
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProps["storeFile"] as String)
                storePassword = keyProps["storePassword"] as String
                keyAlias = keyProps["keyAlias"] as String
                keyPassword = keyProps["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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

dependencies {
    // 1.2.1 pads libdatastore_shared_counter.so's GNU_RELRO segment for 16 KB pages.
    implementation("androidx.datastore:datastore-core:1.2.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")
}
