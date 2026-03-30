//
// mario.c - Super Mario Bros theme on FM synth
//
// Upload via monitor: L 4000, G 4000
// Uses 2 voices: melody (voice 0) + bass (voice 1)
//

#include <femtorv32.h>

// Timing: milliseconds per tick at ~150 BPM
// 150 BPM = 2.5 beats/sec, 1 beat = 400ms, 1 sixteenth = 100ms
#define T16  100   // Sixteenth note
#define T8   200   // Eighth note
#define T4   400   // Quarter note
#define T8D  300   // Dotted eighth
#define T2   800   // Half note

// Rest
#define REST 0

struct note_event {
    uint8_t note;       // MIDI note (0 = rest/off)
    uint16_t duration;  // ms
};

// Mario Bros main theme melody
static const struct note_event melody[] = {
    // Bar 1-2: E5 E5 _ E5 _ C5 E5 _ G5 _ _ _ G4
    {NOTE_E5, T8}, {NOTE_E5, T8}, {REST, T8}, {NOTE_E5, T8},
    {REST, T8}, {NOTE_C5, T8}, {NOTE_E5, T8}, {REST, T8},
    {NOTE_G5, T4}, {REST, T4}, {NOTE_G4, T4}, {REST, T4},

    // Bar 3-4: C5 _ _ G4 _ _ E4 _ _ A4 _ B4 _ Bb4 A4
    {NOTE_C5, T8D}, {REST, T8}, {NOTE_G4, T8D}, {REST, T8},
    {NOTE_E4, T8D}, {REST, T8}, {NOTE_A4, T8}, {REST, T8},
    {NOTE_B4, T8}, {REST, T8}, {76, T8},  // Bb4=70
    {NOTE_A4, T8},

    // Bar 5-6: G4 E5 G5 A5 _ F5 G5 _ E5 _ C5 D5 B4
    {NOTE_G4, T8D}, {NOTE_E5, T8D}, {NOTE_G5, T8},
    {NOTE_A5, T8}, {REST, T8}, {NOTE_F5, T8}, {NOTE_G5, T8},
    {REST, T8}, {NOTE_E5, T8}, {REST, T8},
    {NOTE_C5, T8}, {NOTE_D5, T8}, {NOTE_B4, T8},

    // Bar 7-8 (repeat of 3-4)
    {NOTE_C5, T8D}, {REST, T8}, {NOTE_G4, T8D}, {REST, T8},
    {NOTE_E4, T8D}, {REST, T8}, {NOTE_A4, T8}, {REST, T8},
    {NOTE_B4, T8}, {REST, T8}, {70, T8},  // Bb4
    {NOTE_A4, T8},

    // Bar 9-10: G4 E5 G5 A5 _ F5 G5 _ E5 _ C5 D5 B4
    {NOTE_G4, T8D}, {NOTE_E5, T8D}, {NOTE_G5, T8},
    {NOTE_A5, T8}, {REST, T8}, {NOTE_F5, T8}, {NOTE_G5, T8},
    {REST, T8}, {NOTE_E5, T8}, {REST, T8},
    {NOTE_C5, T8}, {NOTE_D5, T8}, {NOTE_B4, T8},

    {REST, T4},  // End
    {0xFF, 0},   // Terminator
};

// Simple bass line
static const struct note_event bass[] = {
    // Bar 1-2
    {NOTE_D3, T8}, {NOTE_D3, T8}, {REST, T8}, {NOTE_D3, T8},
    {REST, T8}, {NOTE_D3, T8}, {NOTE_D3, T8}, {REST, T8},
    {NOTE_G3, T4}, {REST, T4}, {NOTE_G3, T4}, {REST, T4},

    // Bar 3-4
    {NOTE_G3, T8D}, {REST, T8}, {NOTE_E3, T8D}, {REST, T8},
    {NOTE_C3, T8D}, {REST, T8}, {NOTE_F3, T8}, {REST, T8},
    {NOTE_G3, T8}, {REST, T8}, {NOTE_G3, T8}, {NOTE_F3, T8},

    // Bar 5-6
    {NOTE_E3, T8D}, {NOTE_C4, T8D}, {NOTE_E4, T8},
    {NOTE_F4, T8}, {REST, T8}, {NOTE_D4, T8}, {NOTE_E4, T8},
    {REST, T8}, {NOTE_C4, T8}, {REST, T8},
    {NOTE_A3, T8}, {NOTE_B3, T8}, {NOTE_G3, T8},

    // Bar 7-8
    {NOTE_G3, T8D}, {REST, T8}, {NOTE_E3, T8D}, {REST, T8},
    {NOTE_C3, T8D}, {REST, T8}, {NOTE_F3, T8}, {REST, T8},
    {NOTE_G3, T8}, {REST, T8}, {NOTE_G3, T8}, {NOTE_F3, T8},

    // Bar 9-10
    {NOTE_E3, T8D}, {NOTE_C4, T8D}, {NOTE_E4, T8},
    {NOTE_F4, T8}, {REST, T8}, {NOTE_D4, T8}, {NOTE_E4, T8},
    {REST, T8}, {NOTE_C4, T8}, {REST, T8},
    {NOTE_A3, T8}, {NOTE_B3, T8}, {NOTE_G3, T8},

    {REST, T4},
    {0xFF, 0},
};

// Start timer as free-running counter (set to max value)
static void timer_init(void) {
    IO_OUT(IO_TIMER, 0xFFFFFFFF);
}

static void delay_ms(int ms) {
    // Hardware timer counts at 25MHz: 25000 ticks = 1ms
    uint32_t ticks = (uint32_t)ms * 25000;
    uint32_t start = IO_IN(IO_TIMER);
    while ((IO_IN(IO_TIMER) - start) < ticks);
}

int main(void) {
    // Start hardware timer as free-running counter
    timer_init();

    // Set up voices
    synth_set_preset(0, SYNTH_LEAD);    // Melody voice
    synth_set_preset(1, SYNTH_BASS);    // Bass voice

    // Play the theme (loop 2 times)
    for (int loop = 0; loop < 2; loop++) {
        int m_idx = 0;
        int b_idx = 0;
        int m_time = 0;  // Time remaining on current melody note (ms)
        int b_time = 0;  // Time remaining on current bass note

        // Load first notes
        while (melody[m_idx].note != 0xFF || bass[b_idx].note != 0xFF) {
            // Start melody note if ready
            if (m_time <= 0 && melody[m_idx].note != 0xFF) {
                if (melody[m_idx].note == REST) {
                    synth_note_off(0);
                } else {
                    synth_note_on(0, melody[m_idx].note, 200);
                }
                m_time = melody[m_idx].duration;
                m_idx++;
            }

            // Start bass note if ready
            if (b_time <= 0 && bass[b_idx].note != 0xFF) {
                if (bass[b_idx].note == REST) {
                    synth_note_off(1);
                } else {
                    synth_note_on(1, bass[b_idx].note, 160);
                }
                b_time = bass[b_idx].duration;
                b_idx++;
            }

            // Advance time by the smaller remaining duration
            int step = m_time;
            if (b_time > 0 && (b_time < step || step <= 0))
                step = b_time;
            if (step <= 0) step = T16;

            delay_ms(step);
            m_time -= step;
            b_time -= step;
        }

        // Gap between loops
        synth_all_off();
        delay_ms(1000);
    }

    synth_all_off();
    return 0;
}
