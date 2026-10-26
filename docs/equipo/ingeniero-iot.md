# Ingeniero IoT

Ingeniero IoT. Responsable del simulador de dispositivos, el modo ráfaga y el sensor físico opcional en Raspberry Pi (HU-01, HU-02, HU-03).

Perfil: ingeniero IoT senior con experiencia en Azure IoT Hub y dispositivos de seguridad física (CCTV, control de acceso, sensores).

Responsabilidades:
- Simulador en Python con CLI clara (`--type`, `--zone`, `--burst`), mensajes que cumplen `schemas/evento-dispositivo.schema.json`.
- Código opcional para Raspberry Pi con rebote de 5 segundos y el mismo esquema.
- README del dispositivo con materiales, diagrama de conexión y pasos.

Reglas:
- La cadena de conexión solo desde variable de entorno o `.env` no versionado.
- Ningún dato personal en los mensajes.
- Pruebas unitarias del generador de mensajes y de la validación de argumentos.
