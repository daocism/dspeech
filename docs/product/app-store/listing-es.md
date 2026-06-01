# Borrador de ficha de App Store - español

Estado: texto preparado. No enviar ni publicar sin aprobación de Andrei.

## Campos de metadatos

| Campo | Borrador |
|---|---|
| Nombre, máximo 30 caracteres | Dspeech ATC |
| Subtítulo, máximo 30 caracteres | ATC privado en texto |
| Texto promocional, máximo 100 caracteres | Transcripción ATC en tu iPhone. Texto grande en cabina, offline-first, sin cuenta. |
| URL de soporte | BLOQUEADO - se requiere URL pública de soporte antes de enviar metadatos a App Store |
| URL de marketing | BLOQUEADO - URL pública opcional de marketing aún no aprobada |
| Palabras clave, máximo 100 bytes | atc,pilot,cockpit,aviation,transcript,radio,flight,intercom,offline,airband,student |

## Descripción, máximo 4000 caracteres

Dspeech convierte audio en vivo de cabina y ATC en texto grande y fácil de leer en tu iPhone, con privacidad por defecto.

Tu audio se queda en el dispositivo. Dspeech está diseñado para reconocimiento local de voz, ajustes locales y uso sin cuenta. El objetivo actual de la app no incluye SDK de analítica, SDK publicitario ni ruta de seguimiento.

Por qué lo usan los pilotos:

- Leer comunicaciones ATC como texto grande pensado para cabina.
- Mantener el audio original de radio como referencia principal mientras el texto sirve de ayuda suplementaria.
- Ver el indicador LOCAL en la pantalla principal.
- Ver indicadores de ruta de entrada sin enviar audio de cabina a un servidor.
- Mantener en el dispositivo los ajustes del filtro de voz y el estado del paquete de modelo.

Privacidad por diseño:

- No requiere cuenta.
- En modo local no se sube audio.
- En modo local no se suben transcripciones.
- No hay seguimiento de ubicación.
- No hay seguimiento publicitario.
- La app no envía mensajes salientes de soporte o ventas.

Aviso importante de aviación:

Dspeech es una ayuda suplementaria de cabina. No es aviónica certificada, no es una autoridad ATC y no sustituye la escucha de radio, el criterio del piloto, las instrucciones de ATC, los procedimientos de la aeronave ni el equipo requerido. El audio original y las autorizaciones oficiales siguen siendo la referencia autoritativa.

Aviso de hardware:

Dspeech no promete compatibilidad con todos los auriculares, intercoms, aviones, rutas Bluetooth o adaptadores cableados. Usa los indicadores de ruta de la app y valida tu configuración antes de apoyarte en cualquier flujo de trabajo.

Aviso de facturación:

El plan de producto de Dspeech usa paquetes de horas de uso en lugar de una suscripción plana. Las compras con StoreKit no forman parte de este readiness-slice y solo deben configurarse después de aprobar la implementación de facturación.

## Notas para release manager

- Categoría principal: Navigation.
- Categoría secundaria: Productivity.
- La disponibilidad por país debe seguir estrictamente `docs/product/pricing-top20-aviation.md`.
- No afirmar traducción, fiabilidad certificada de cabina ni soporte de hardware validado hasta que la implementación y la evidencia estén listas.
- No publicar respuestas de privacidad mediante automatización; la publicación final debe hacerse manualmente en App Store Connect tras aprobación de Andrei.
