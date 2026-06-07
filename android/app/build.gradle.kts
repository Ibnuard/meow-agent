plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // VM module: libproot.so is an ARM Linux executable we spawn as a child
    // process, NOT a real shared library. AGP 8+ defaults to leaving .so
    // files inside the APK uncompressed (loaded via dlopen). That doesn't
    // work for our case — we need the binary physically present in
    // nativeLibraryDir with the executable bit set. useLegacyPackaging=true
    // forces the platform to extract jniLibs at install time.
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
}

flutter {
    source = "../.."
}

// VM module: auto-fetch the Termux proot binary before building. This
// vendors libproot.so into jniLibs/arm64-v8a so the APK ships ready to use,
// no separate setup step required by the developer.
//
// Skipped if libproot.so is already present (idempotent).
val fetchProot = tasks.register("fetchProot") {
    val outFile = file("src/main/jniLibs/arm64-v8a/libproot.so")
    outputs.file(outFile)
    onlyIf { !outFile.exists() }
    doLast {
        val script = if (System.getProperty("os.name").lowercase().contains("win")) {
            listOf("powershell", "-ExecutionPolicy", "Bypass", "-File",
                "${rootProject.projectDir}/../scripts/fetch-proot.ps1")
        } else {
            listOf("bash", "${rootProject.projectDir}/../scripts/fetch-proot.sh")
        }
        exec {
            commandLine(script)
            workingDir = file("${rootProject.projectDir}/..")
        }
    }
}

// Wire fetchProot to run before any Android build task that touches jniLibs.
tasks.matching { it.name.startsWith("merge") && it.name.contains("JniLibFolders") }
    .configureEach { dependsOn(fetchProot) }
tasks.matching { it.name.startsWith("preBuild") }
    .configureEach { dependsOn(fetchProot) }
