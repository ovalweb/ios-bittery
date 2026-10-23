# Credits

This tree is ios-sweet (dipa-studio, MIT) ported to the Pixel 3 (blueline).

- **ios-flame** (<https://github.com/NWylynko/ios-flame>, MIT; XNU changes APSL 2.0): the Pixel 4
  port of the same base. Its kernel patches 0082-0124 are merged in `xnu/patches/0096-*` (with
  Pixel 3 adaptations), its shim's PMIC/watchdog code is in `shim/spmi.c` and `shim/shim.c`, and
  `tools/flame-*.py`, `tools/mac-share.sh` and `tools/flamebridge/` are its host tools.
- Through ios-flame: **ios-topaz** (MakrSas), **HackiOS** (OOSEX GANG, APSL 2.0) for the
  Apple80211/wifid and IONetworkStack stand-ins, and **UniXNU** (NativeMetal/NativeAdreno, MIT)
  for the GPU user-client ABI. Licences and details: ios-flame's CREDITS.md.
- **Linux** (mainline and Google's android-msm-crosshatch-4.9) as the register reference for
  the GPI DMA engine, GENI I2C, PMI8998 fuel gauge, TSENS and cpufreq-hw drivers (patches
  0086-0095 are independent implementations).
