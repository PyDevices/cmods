// Direct browser services for the PyDevices MicroPython WebAssembly variant.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <emscripten/emscripten.h>

#include "py/mperrno.h"
#include "py/mpprint.h"
#include "py/nlr.h"
#include "py/runtime.h"
#include "py/objstr.h"
#include "py/objlist.h"

typedef struct {
    int32_t type;
    int32_t x;
    int32_t y;
    int32_t movement_x;
    int32_t movement_y;
    int32_t button;
    int32_t buttons;
    int32_t pressure_milli;
    int32_t pointer_id;
    int32_t pointer_type;
    int32_t primary;
    int32_t delta_x_milli;
    int32_t delta_y_milli;
    int32_t delta_z_milli;
    int32_t delta_mode;
    int32_t location;
    int32_t flags;
    int32_t repeat;
    char key[64];
    char code[64];
} pydevices_event_record_t;

typedef struct {
    volatile uint32_t head;
    volatile uint32_t tail;
    pydevices_event_record_t records[256];
} pydevices_event_ring_t;

static pydevices_event_ring_t event_ring;
static int timer_callback_ids[64];
MP_REGISTER_ROOT_POINTER(mp_obj_t wasm_timer_callbacks[64]);

extern int pydevices_display_register(uintptr_t, size_t, int, int, const char *);
extern void pydevices_display_unregister(void);
extern uintptr_t pydevices_event_poll(size_t *);
extern void pydevices_event_set_buffer(uintptr_t, size_t, size_t);
extern void pydevices_event_clear(void);
extern void pydevices_timer_start(int, int, int);
extern void pydevices_timer_cancel(int);
extern int pydevices_timer_poll(void);
extern int pydevices_audio_state(int);
extern int pydevices_audio_write(uintptr_t, size_t, int, int, int, int, int);
extern int pydevices_audio_read(uintptr_t, size_t, int, int, int, int, int);
extern void pydevices_audio_clear(int);
extern int pydevices_audio_queued(int);
extern uintptr_t pydevices_http_get(const char *, int *, size_t *, uintptr_t *);
extern void pydevices_sleep_ms(int);
extern void pydevices_host_reset(void);
extern void external_call_depth_inc(void);
extern void external_call_depth_dec(void);

void pydevices_bridge_deinit(void) {
    pydevices_host_reset();
    memset(&event_ring, 0, sizeof(event_ring));
    memset(timer_callback_ids, 0, sizeof(timer_callback_ids));
    for (size_t i = 0; i < 64; ++i) {
        MP_STATE_VM(wasm_timer_callbacks)[i] = MP_OBJ_NULL;
    }
}

static mp_obj_t bridge_display_register(size_t n_args, const mp_obj_t *args) {
    mp_buffer_info_t buf;
    mp_get_buffer_raise(args[0], &buf, MP_BUFFER_READ);
    int width = mp_obj_get_int(args[1]);
    int height = mp_obj_get_int(args[2]);
    const char *canvas = n_args > 3 ? mp_obj_str_get_str(args[3]) : "display_canvas";
    if (buf.len < (size_t)width * (size_t)height * 2) {
        mp_raise_ValueError(MP_ERROR_TEXT("framebuffer is smaller than width*height*2"));
    }
    memset(&event_ring, 0, sizeof(event_ring));
    pydevices_event_set_buffer((uintptr_t)&event_ring, 256, sizeof(pydevices_event_record_t));
    return mp_obj_new_bool(pydevices_display_register((uintptr_t)buf.buf, buf.len, width, height, canvas));
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(bridge_display_register_obj, 3, 4, bridge_display_register);

static mp_obj_t bridge_display_unregister(void) {
    pydevices_display_unregister();
    pydevices_event_set_buffer(0, 0, 0);
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(bridge_display_unregister_obj, bridge_display_unregister);

static mp_obj_t bridge_pointer_event(const pydevices_event_record_t *event, mp_obj_t contract) {
    size_t count;
    mp_obj_t *types;
    mp_obj_get_array(contract, &count, &types);
    if (count < 3 || event->type < 1 || event->type > 4) {
        return MP_OBJ_NULL;
    }
    mp_obj_t pos_items[] = { mp_obj_new_int(event->x), mp_obj_new_int(event->y) };
    mp_obj_t pos = mp_obj_new_tuple(2, pos_items);
    bool touch = event->pointer_type != 0;
    if (event->type == 2) {
        if (touch) {
            mp_obj_t args[] = { mp_obj_new_int(0x702), pos, mp_obj_new_int(event->pointer_id), mp_const_none };
            return mp_call_function_n_kw(types[2], 4, 0, args);
        }
        mp_obj_t rel_items[] = { mp_obj_new_int(event->movement_x), mp_obj_new_int(event->movement_y) };
        mp_obj_t button_items[] = {
            mp_obj_new_int(event->buttons & 1 ? 1 : 0),
            mp_obj_new_int(event->buttons & 4 ? 1 : 0),
            mp_obj_new_int(event->buttons & 2 ? 1 : 0),
        };
        mp_obj_t args[] = {
            mp_obj_new_int(0x400), pos, mp_obj_new_tuple(2, rel_items),
            mp_obj_new_tuple(3, button_items), mp_const_false, mp_const_none,
        };
        return mp_call_function_n_kw(types[0], 6, 0, args);
    }
    bool down = event->type == 1;
    mp_obj_t button_args[] = {
        mp_obj_new_int(down ? 0x401 : 0x402), pos, mp_obj_new_int(event->button + 1),
        mp_obj_new_bool(touch), mp_const_none,
    };
    mp_obj_t button = mp_call_function_n_kw(types[1], 5, 0, button_args);
    if (!touch) {
        return button;
    }
    mp_obj_t finger_args[] = {
        mp_obj_new_int(down ? 0x700 : 0x701), pos,
        mp_obj_new_int(event->pointer_id), mp_const_none,
    };
    mp_obj_t output[2] = {
        mp_call_function_n_kw(types[2], 4, 0, finger_args), button,
    };
    return mp_obj_new_list(2, output);
}

static mp_obj_t bridge_fast_event(const pydevices_event_record_t *event, mp_obj_t contract) {
    if (contract != mp_const_none) {
        mp_obj_t converted = bridge_pointer_event(event, contract);
        if (converted != MP_OBJ_NULL) {
            return converted;
        }
    }
    if (event->type >= 1 && event->type <= 4) {
        mp_obj_t items[] = {
            mp_obj_new_int(event->type), mp_obj_new_int(event->x),
            mp_obj_new_int(event->y), mp_obj_new_int(event->movement_x),
            mp_obj_new_int(event->movement_y), mp_obj_new_int(event->button),
            mp_obj_new_int(event->buttons), mp_obj_new_int(event->pointer_id),
            mp_obj_new_int(event->pointer_type),
        };
        return mp_obj_new_tuple(sizeof(items) / sizeof(items[0]), items);
    }
    if (event->type == 5) {
        mp_obj_t items[] = {
            mp_obj_new_int(event->type), mp_obj_new_int(event->x),
            mp_obj_new_int(event->y), mp_obj_new_int(event->delta_x_milli),
            mp_obj_new_int(event->delta_y_milli),
        };
        return mp_obj_new_tuple(sizeof(items) / sizeof(items[0]), items);
    }
    if (event->type == 6 || event->type == 7) {
        mp_obj_t items[] = {
            mp_obj_new_int(event->type), mp_obj_new_str(event->key, strlen(event->key)),
            mp_obj_new_str(event->code, strlen(event->code)), mp_obj_new_int(event->location),
            mp_obj_new_int(event->flags),
        };
        return mp_obj_new_tuple(sizeof(items) / sizeof(items[0]), items);
    }
    return mp_obj_new_tuple(1, (mp_obj_t[]){ mp_obj_new_int(event->type) });
}

static mp_obj_t bridge_poll_event(size_t n_args, const mp_obj_t *args) {
    mp_obj_t contract = n_args ? args[0] : mp_const_none;
    uint32_t tail = event_ring.tail;
    if (tail != event_ring.head) {
        mp_obj_t result = bridge_fast_event(&event_ring.records[tail], contract);
        event_ring.tail = (tail + 1) % 256;
        return result;
    }
    size_t len = 0;
    uintptr_t ptr = pydevices_event_poll(&len);
    if (!ptr) {
        return mp_const_none;
    }
    mp_obj_t result = mp_obj_new_str((const char *)ptr, len);
    free((void *)ptr);
    return result;
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(bridge_poll_event_obj, 0, 1, bridge_poll_event);

static mp_obj_t bridge_poll_events(mp_obj_t contract) {
    mp_obj_t output = mp_obj_new_list(0, NULL);
    size_t raw_count = 0;
    while (event_ring.tail != event_ring.head) {
        uint32_t tail = event_ring.tail;
        if (event_ring.records[tail].type < 1 || event_ring.records[tail].type > 4) {
            raw_count++;
        }
        mp_obj_t event = bridge_fast_event(&event_ring.records[tail], contract);
        event_ring.tail = (tail + 1) % 256;
        if (mp_obj_get_type(event) == &mp_type_list) {
            size_t count;
            mp_obj_t *items;
            mp_obj_get_array(event, &count, &items);
            for (size_t i = 0; i < count; ++i) {
                mp_obj_list_append(output, items[i]);
            }
        } else {
            mp_obj_list_append(output, event);
        }
    }
    while (true) {
        size_t len = 0;
        uintptr_t ptr = pydevices_event_poll(&len);
        if (!ptr) {
            break;
        }
        mp_obj_list_append(output, mp_obj_new_str((const char *)ptr, len));
        raw_count++;
        free((void *)ptr);
    }
    mp_obj_t items[] = {
        ((mp_obj_list_t *)MP_OBJ_TO_PTR(output))->len ? output : mp_const_none,
        mp_obj_new_int_from_uint(raw_count),
    };
    return mp_obj_new_tuple(2, items);
}
static MP_DEFINE_CONST_FUN_OBJ_1(bridge_poll_events_obj, bridge_poll_events);

static mp_obj_t bridge_clear_events(void) {
    event_ring.head = event_ring.tail = 0;
    pydevices_event_clear();
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_0(bridge_clear_events_obj, bridge_clear_events);

static mp_obj_t bridge_timer_start(size_t n_args, const mp_obj_t *args) {
    int id = mp_obj_get_int(args[0]);
    if (n_args == 4) {
        bool stored = false;
        for (size_t i = 0; i < 64; ++i) {
            if (MP_STATE_VM(wasm_timer_callbacks)[i] == MP_OBJ_NULL || timer_callback_ids[i] == id) {
                timer_callback_ids[i] = id;
                MP_STATE_VM(wasm_timer_callbacks)[i] = args[3];
                stored = true;
                break;
            }
        }
        if (!stored) {
            mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("WASM timer callback table is full"));
        }
    }
    pydevices_timer_start(id, mp_obj_get_int(args[1]), mp_obj_is_true(args[2]));
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(bridge_timer_start_obj, 3, 4, bridge_timer_start);

EMSCRIPTEN_KEEPALIVE void pydevices_timer_dispatch(int id) {
    external_call_depth_inc();
    for (size_t i = 0; i < 64; ++i) {
        mp_obj_t callback = MP_STATE_VM(wasm_timer_callbacks)[i];
        if (callback != MP_OBJ_NULL && timer_callback_ids[i] == id) {
            nlr_buf_t nlr;
            if (nlr_push(&nlr) == 0) {
                mp_call_function_0(callback);
                nlr_pop();
            } else {
                mp_obj_print_exception(&mp_plat_print, MP_OBJ_FROM_PTR(nlr.ret_val));
            }
            external_call_depth_dec();
            return;
        }
    }
    external_call_depth_dec();
}

static mp_obj_t bridge_timer_cancel(mp_obj_t id) {
    int timer_id = mp_obj_get_int(id);
    pydevices_timer_cancel(timer_id);
    for (size_t i = 0; i < 64; ++i) {
        if (MP_STATE_VM(wasm_timer_callbacks)[i] != MP_OBJ_NULL && timer_callback_ids[i] == timer_id) {
            MP_STATE_VM(wasm_timer_callbacks)[i] = MP_OBJ_NULL;
            break;
        }
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(bridge_timer_cancel_obj, bridge_timer_cancel);

static mp_obj_t bridge_timer_poll(void) {
    int id = pydevices_timer_poll();
    return id < 0 ? mp_const_none : mp_obj_new_int(id);
}
static MP_DEFINE_CONST_FUN_OBJ_0(bridge_timer_poll_obj, bridge_timer_poll);

static mp_obj_t bridge_audio_state(mp_obj_t input) {
    return mp_obj_new_int(pydevices_audio_state(mp_obj_is_true(input)));
}
static MP_DEFINE_CONST_FUN_OBJ_1(bridge_audio_state_obj, bridge_audio_state);

static mp_obj_t bridge_audio_write(size_t n_args, const mp_obj_t *args) {
    mp_buffer_info_t buf;
    mp_get_buffer_raise(args[0], &buf, MP_BUFFER_READ);
    int result = pydevices_audio_write((uintptr_t)buf.buf, buf.len,
        mp_obj_get_int(args[1]), mp_obj_get_int(args[2]), mp_obj_get_int(args[3]),
        mp_obj_is_true(args[4]), mp_obj_is_true(args[5]));
    if (result < 0) {
        mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("audio output is not enabled"));
    }
    return mp_obj_new_int(result);
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(bridge_audio_write_obj, 6, 6, bridge_audio_write);

static mp_obj_t bridge_audio_read(size_t n_args, const mp_obj_t *args) {
    mp_buffer_info_t buf;
    mp_get_buffer_raise(args[0], &buf, MP_BUFFER_WRITE);
    int result = pydevices_audio_read((uintptr_t)buf.buf, buf.len,
        mp_obj_get_int(args[1]), mp_obj_get_int(args[2]), mp_obj_get_int(args[3]),
        mp_obj_is_true(args[4]), mp_obj_is_true(args[5]));
    if (result < 0) {
        mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("microphone is not enabled"));
    }
    return mp_obj_new_int(result);
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(bridge_audio_read_obj, 6, 6, bridge_audio_read);

static mp_obj_t bridge_audio_clear(mp_obj_t input) {
    pydevices_audio_clear(mp_obj_is_true(input));
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(bridge_audio_clear_obj, bridge_audio_clear);

static mp_obj_t bridge_audio_queued(mp_obj_t input) {
    return mp_obj_new_int(pydevices_audio_queued(mp_obj_is_true(input)));
}
static MP_DEFINE_CONST_FUN_OBJ_1(bridge_audio_queued_obj, bridge_audio_queued);

static mp_obj_t bridge_http_get(mp_obj_t url_obj) {
    const char *url = mp_obj_str_get_str(url_obj);
    int status = 0;
    size_t len = 0;
    uintptr_t final_url_ptr = 0;
    uintptr_t data_ptr = pydevices_http_get(url, &status, &len, &final_url_ptr);
    if (!data_ptr && status == 0) {
        mp_raise_msg_varg(&mp_type_OSError, MP_ERROR_TEXT("Fetch failed: %s"), url);
    }
    mp_obj_t items[3] = {
        mp_obj_new_int(status),
        mp_obj_new_bytes((const byte *)data_ptr, len),
        final_url_ptr ? mp_obj_new_str((const char *)final_url_ptr, strlen((const char *)final_url_ptr)) : url_obj,
    };
    free((void *)data_ptr);
    free((void *)final_url_ptr);
    return mp_obj_new_tuple(3, items);
}
static MP_DEFINE_CONST_FUN_OBJ_1(bridge_http_get_obj, bridge_http_get);

static mp_obj_t bridge_sleep_ms(mp_obj_t ms) {
    pydevices_sleep_ms(mp_obj_get_int(ms));
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(bridge_sleep_ms_obj, bridge_sleep_ms);

static const mp_rom_map_elem_t bridge_globals_table[] = {
    { MP_ROM_QSTR(MP_QSTR___name__), MP_ROM_QSTR(MP_QSTR__wasm_bridge) },
    { MP_ROM_QSTR(MP_QSTR_register_framebuffer), MP_ROM_PTR(&bridge_display_register_obj) },
    { MP_ROM_QSTR(MP_QSTR_unregister_framebuffer), MP_ROM_PTR(&bridge_display_unregister_obj) },
    { MP_ROM_QSTR(MP_QSTR_poll_event), MP_ROM_PTR(&bridge_poll_event_obj) },
    { MP_ROM_QSTR(MP_QSTR_poll_events), MP_ROM_PTR(&bridge_poll_events_obj) },
    { MP_ROM_QSTR(MP_QSTR_clear_events), MP_ROM_PTR(&bridge_clear_events_obj) },
    { MP_ROM_QSTR(MP_QSTR_timer_start), MP_ROM_PTR(&bridge_timer_start_obj) },
    { MP_ROM_QSTR(MP_QSTR_timer_cancel), MP_ROM_PTR(&bridge_timer_cancel_obj) },
    { MP_ROM_QSTR(MP_QSTR_timer_poll), MP_ROM_PTR(&bridge_timer_poll_obj) },
    { MP_ROM_QSTR(MP_QSTR_audio_state), MP_ROM_PTR(&bridge_audio_state_obj) },
    { MP_ROM_QSTR(MP_QSTR_audio_write), MP_ROM_PTR(&bridge_audio_write_obj) },
    { MP_ROM_QSTR(MP_QSTR_audio_readinto), MP_ROM_PTR(&bridge_audio_read_obj) },
    { MP_ROM_QSTR(MP_QSTR_audio_clear), MP_ROM_PTR(&bridge_audio_clear_obj) },
    { MP_ROM_QSTR(MP_QSTR_audio_queued_size), MP_ROM_PTR(&bridge_audio_queued_obj) },
    { MP_ROM_QSTR(MP_QSTR_http_get), MP_ROM_PTR(&bridge_http_get_obj) },
    { MP_ROM_QSTR(MP_QSTR_sleep_ms), MP_ROM_PTR(&bridge_sleep_ms_obj) },
};
static MP_DEFINE_CONST_DICT(bridge_globals, bridge_globals_table);

const mp_obj_module_t wasm_bridge_module = {
    .base = { &mp_type_module },
    .globals = (mp_obj_dict_t *)&bridge_globals,
};
MP_REGISTER_MODULE(MP_QSTR__wasm_bridge, wasm_bridge_module);
