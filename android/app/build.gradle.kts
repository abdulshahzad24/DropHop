plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.local.drophop.mobile"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.local.drophop.mobile"
        minSdk = 29            // Android 10+: saves downloads to Downloads/DropHop without extra permissions
        targetSdk = 34
        versionCode = 2
        versionName = "1.1"
    }

    // One fixed key for every build. GitHub's build machines create a brand-new debug key on every run, and Android
    // refuses to install an update signed with a different key than the installed app ("App not installed").
    signingConfigs {
        create("shared") {
            storeFile = file("drophop.keystore")
            storePassword = "drophop-shared"
            keyAlias = "drophop"
            keyPassword = "drophop-shared"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Personal-use signing so `assembleRelease` gives an installable APK (not for the Play Store).
            signingConfig = signingConfigs.getByName("shared")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures { compose = true }
    composeOptions { kotlinCompilerExtensionVersion = "1.5.14" }

    packaging { resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" } }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.03")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
}
