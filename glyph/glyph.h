#ifndef FOSFORO_GLYPH_H
#define FOSFORO_GLYPH_H

/* Graphic runes drawn from geometry instead of the font, sized to the cell in
   device pixels, so neighbours meet without seams: box drawing U+2500-257F,
   blocks and shades U+2580-259F, braille U+2800-28FF and the Powerline
   separators U+E0B0-E0B3. */

#include <stdint.h>

int glyph_is_graphic(uint32_t cp);

/* Writes w*h coverage bytes (0..255, row 0 at the top) into out. Returns 0
   and leaves out alone when cp is not a graphic rune. */
int glyph_draw(uint32_t cp, int w, int h, uint8_t *out);

#endif
