import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) {
        propertiesFile.inputStream().use(::load)
    }
}

val releaseStoreFilePath = System.getenv("ANDROID_KEYSTORE_PATH")
    ?.takeIf { it.isNotBlank() }
    ?: keystoreProperties.getProperty("storeFile")
val releaseStorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
    ?.takeIf { it.isNotBlank() }
    ?: keystoreProperties.getProperty("storePassword")
val releaseKeyAlias = System.getenv("ANDROID_KEY_ALIAS")
    ?.takeIf { it.isNotBlank() }
    ?: keystoreProperties.getProperty("keyAlias")
val releaseKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")
    ?.takeIf { it.isNotBlank() }
    ?: keystoreProperties.getProperty("keyPassword")

val missingReleaseSigningValues = mapOf(
    "ANDROID_KEYSTORE_PATH/storeFile" to releaseStoreFilePath,
    "ANDROID_KEYSTORE_PASSWORD/storePassword" to releaseStorePassword,
    "ANDROID_KEY_ALIAS/keyAlias" to releaseKeyAlias,
    "ANDROID_KEY_PASSWORD/keyPassword" to releaseKeyPassword,
).filterValues { it.isNullOrBlank() }.keys

val isReleaseTask = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (isReleaseTask && missingReleaseSigningValues.isNotEmpty()) {
    throw GradleException(
        "Release signing is not configured. Missing: " +
            missingReleaseSigningValues.joinToString(", "),
    )
}

android {
    namespace = "com.meowagent.meow_agent"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.meowagent.meow_agent"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_secure_storage uses EncryptedSharedPreferences which requires API 23.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            if (missingReleaseSigningValues.isEmpty()) {
                storeFile = file(requireNotNull(releaseStoreFilePath))
                storePassword = requireNotNull(releaseStorePassword)
                keyAlias = requireNotNull(releaseKeyAlias)
                keyPassword = requireNotNull(releaseKeyPassword)
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }

    // Ensure native libraries (proot, loader, libtalloc, libandroid-shmem)
    // are extracted to the filesystem at install time. proot needs real file
    // paths — it cannot exec from inside the APK.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Shizuku — ADB-level shell access for wake/unlock/input automation.
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    // Coroutines for VM runtime async ops (download, install, exec).
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // Extract Termux .deb payloads downloaded in-app for the VM runtime.
    implementation("org.tukaani:xz:1.10")
}

flutter {
    source = "../.."
}
