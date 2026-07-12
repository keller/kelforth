\ temperature.fs — Fahrenheit to Celsius, the manual way.
\ Formula: C = (F - 32) * 5 / 9
\ Notice we can't name the formula yet (no user-defined words until
\ stage 1), so we repeat it for each conversion.

212 32 - 5 * 9 / . cr    \ boiling point  -> 100
 32 32 - 5 * 9 / . cr    \ freezing point -> 0
 98 32 - 5 * 9 / . cr    \ body-ish temp  -> 36
-40 32 - 5 * 9 / . cr    \ the crossover  -> -40
