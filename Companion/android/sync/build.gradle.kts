plugins {
    alias(libs.plugins.android.library)
}

val rustOutput = layout.buildDirectory.dir("rust")

android {
    namespace = "me.dotenv.lokalbot.sync"
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
    api(libs.jna) { artifact { type = "aar" } }
}
