# Constitución del proyecto

Principios no negociables. Si una decisión de diseño o de código choca con alguno, gana la constitución y se escala a Daniel.

## Artículo 1. La persona decide
El agente clasifica, contextualiza, resume y propone. Nunca ejecuta una acción con efecto en el mundo físico ni sobre otras personas: llamar a autoridades, abrir o bloquear accesos, confrontar o retener a alguien, cerrar un caso como falsa alarma o cambiar un protocolo. Toda decisión queda registrada con quién, qué y cuándo.

## Artículo 2. Especificación primero
No se escribe código de producción sin una historia de usuario aprobada y criterios de aceptación verificables. Un cambio de alcance se propone y se aprueba antes de implementarse.

## Artículo 3. Trazabilidad completa
Cada tarea, commit y prueba se puede rastrear a una historia (HU-xx) y a un criterio (CA-xx.y). Lo que no se puede rastrear no entra.

## Artículo 4. Seguridad por diseño
- Cero secretos en el repositorio. Identidades administradas, Key Vault y archivos `.env.example`.
- Permisos mínimos: la función solo puede escribir en el sitio de SharePoint de la demo (Sites.Selected), nunca en todo el tenant.
- El agente usa una cuenta de servicio dedicada, nunca la de un administrador global.
- El payload de un evento no lleva datos personales ni imágenes.

## Artículo 5. Datos ficticios
Zonas, cámaras, protocolos y nombres son inventados. Nada en el repositorio puede identificar una empresa, instalación o persona real.

## Artículo 6. Comunidad, no comercio
El repositorio es público y educativo. Sin logos de terceros, sin mensajes comerciales de la empresa del speaker ni de ningún proveedor. Licencia MIT.

## Artículo 7. Demostrable en vivo
Todo lo que se muestra en la charla debe funcionar en menos de 60 segundos de punta a punta, poder reiniciarse con un comando y tener un respaldo grabado. Lo simple y confiable gana sobre lo sofisticado.

## Artículo 8. Verdad sobre el producto
No se afirma ninguna capacidad de Microsoft 365, Copilot Studio o Azure sin verificarla en documentación oficial. Lo no verificado se marca como riesgo.

## Artículo 9. Costo controlado
La demo completa debe costar menos de USD 20 al mes en Azure, sin contar licencias de Microsoft 365 y Copilot Studio. Todo recurso se puede borrar con un comando.
