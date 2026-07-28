plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStorePath = System.getenv("WUJIAN_RELEASE_STORE_FILE")
val releaseStorePassword = System.getenv("WUJIAN_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = System.getenv("WUJIAN_RELEASE_KEY_ALIAS")
val releaseKeyPassword = System.getenv("WUJIAN_RELEASE_KEY_PASSWORD")
val releaseSigningReady =
    listOf(
        releaseStorePath,
        releaseStorePassword,
        releaseKeyAlias,
        releaseKeyPassword,
    ).all { !it.isNullOrBlank() }
val requestedReleaseBuild =
    gradle.startParameter.taskNames.any { taskName ->
        taskName.contains("release", ignoreCase = true)
    }

if (requestedReleaseBuild && !releaseSigningReady) {
    throw GradleException(
        "Release signing is not configured. Set WUJIAN_RELEASE_STORE_FILE, " +
            "WUJIAN_RELEASE_STORE_PASSWORD, WUJIAN_RELEASE_KEY_ALIAS and " +
            "WUJIAN_RELEASE_KEY_PASSWORD.",
    )
}

android {
    namespace = "com.wujian.app.icheck"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.wujian.app.icheck"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}
