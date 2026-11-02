// Wraps the lokalbot-sync Rust crate for Android. `Scripts/build-sync-android.sh`
// writes the shared libraries and the UniFFI Kotlin bindings into build/rust;
// this module only packages them. Running `clean` deletes them, so run the
// script again afterwards.
plugins {
    alias(libs.plugins.android.library)
}

val rustOutput = layout.buildDirectory.dir("rust")

android {
    namespace = "me.dotenv.lokalbot.sync"
    // Current AndroidX releases need the Android 17 SDK to compile; runtime
    // behavior follows targetSdk.
    compileSdk = 37

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }

    sourceSets {
        getByName("main") {
            kotlin.directories.add(rustOutput.get().dir("kotlin").asFile.path)
            jniLibs.directories.add(rustOutput.get().dir("jniLibs").asFile.path)
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // The AAR carries JNA's Android native libraries.
    api(libs.jna) { artifact { type = "aar" } }
}
