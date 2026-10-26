# Protocolo PR-03: Acceso denegado repetido

**Versión:** 1.0 · octubre de 2026 · Documento ficticio para la demo "Del sensor al agente".

## Alcance

Aplica cuando un lector de credenciales rechaza varios intentos seguidos en la misma puerta de una Sede Demo, por ejemplo en el archivo documental (Z-05). Lo usa el supervisor de turno del centro de operaciones.

El Agente de Operaciones solo clasifica, resume y propone una severidad. Ninguna acción física depende de él.

## Pasos

1. Verifica en la tarjeta la zona, la hora local y el número de intentos rechazados.
2. Revisa la cámara asignada a la zona y observa si es la misma persona la que lo intenta.
3. Consulta si hay un reporte abierto de credencial vencida, perdida o con falla del lector en esa zona.
4. Compara con otros lectores de la sede: rechazos en varias puertas a la vez pesan más que en una sola.
5. Confirma si el evento ocurrió fuera del horario de 06:00 a 18:00. En ese caso la propuesta de severidad sube un nivel.
6. Registra en la tarjeta una observación corta con lo que viste y elige una decisión.

## Señales para la severidad

- Intentos en varias puertas o en una zona de severidad base Alta: la propuesta puede subir un nivel.
- Falla conocida del lector o credencial vencida ya reportada: la propuesta puede bajar un nivel.
- La propuesta nunca se aleja más de un nivel de la severidad inicial.

## Lo que decide una persona

Estas decisiones son siempre del supervisor y quedan registradas con quién, qué y cuándo:

- Escalar a autoridades o al equipo de respuesta de la sede.
- Abrir o bloquear la puerta, o suspender una credencial.
- Enviar a alguien al lector, confrontar o retener a una persona.
- Cerrar el incidente como falsa alarma.
- Cambiar este protocolo.
