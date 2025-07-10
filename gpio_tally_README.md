# CinePi5 GPIO Tally Driver

## Features
- Device Tree configuration
- Dual control interfaces:
- Sysfs (recommended for scripts)
- Character device (for legacy apps)
- Configurable initial state
- Rate-limited error logging

## Device Tree
```dts
tally_red {
compatible = "cinesoft,gpio-tally";
tally-gpios = <&gpio1 18 GPIO_ACTIVE_HIGH>;
initial-on; // Optional
};