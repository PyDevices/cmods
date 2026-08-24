// Browser half of the builtin _wasm_bridge module. All buffer views are
// reacquired from HEAPU8 at the point of use so ALLOW_MEMORY_GROWTH is safe.
mergeInto(LibraryManager.library, {
    // Per-canvas display state (framebuffer/paint + its own input queue),
    // keyed by canvas id string. Everything else (audio, timers, http) stays
    // process-global — only display + input needs to be per-canvas, since
    // EncoderEmu-style secondary surfaces (lv_encoder_emu.py) register their
    // own canvas alongside the primary display.
    $pydevices_state: {
        displays: new Map(),
        animation: 0,
        timers: new Map(),
        firedTimers: [],
        timerFirings: [],
        timerDeliveries: [],
        audioContext: null,
        audioEnabled: false,
        microphoneEnabled: false,
        audioEnd: 0,
        audioSources: new Set(),
        audioQueuedBytes: 0,
        inputFrames: [],
        mediaStream: null,
        mediaNode: null,
        processor: null,
    },

    $pydevices_write_event: (ptr, event) => {
        const types={pointerdown:1,pointermove:2,pointerup:3,pointercancel:4,wheel:5,keydown:6,keyup:7,focus:8,blur:9};
        const pointerTypes={mouse:0,touch:1,pen:2};
        const ints=new Int32Array(HEAPU8.buffer,ptr,18);
        ints[0]=types[event.type]||0;
        ints[1]=event.x||0; ints[2]=event.y||0;
        ints[3]=event.movementX||0; ints[4]=event.movementY||0;
        ints[5]=event.button||0; ints[6]=event.buttons||0;
        ints[7]=Math.round((event.pressure||0)*1000); ints[8]=event.pointerId||0;
        ints[9]=pointerTypes[event.pointerType]||0; ints[10]=+!!event.primary;
        ints[11]=Math.round((event.deltaX||0)*1000); ints[12]=Math.round((event.deltaY||0)*1000);
        ints[13]=Math.round((event.deltaZ||0)*1000); ints[14]=event.deltaMode||0;
        ints[15]=event.location||0;
        ints[16]=(+!!event.altKey)|(+!!event.ctrlKey<<1)|(+!!event.metaKey<<2)|(+!!event.shiftKey<<3);
        ints[17]=+!!event.repeat;
        stringToUTF8(event.key||'',ptr+72,64);
        stringToUTF8(event.code||'',ptr+136,64);
        return ints[0];
    },

    $pydevices_get_display__deps: ['$pydevices_state'],
    $pydevices_get_display: (canvasId) => {
        let display = pydevices_state.displays.get(canvasId);
        if (!display) {
            display = {framebuffer:null, canvas:null, context:null, image:null, framesPainted:0, eventRing:null, events:[]};
            pydevices_state.displays.set(canvasId, display);
        }
        return display;
    },

    $pydevices_push_event__deps: ['$pydevices_get_display', '$pydevices_write_event'],
    $pydevices_push_event: (canvasId, event) => {
        const display = pydevices_get_display(canvasId);
        const ring = display.eventRing;
        if(ring && event.type!=='gamepad') {
            const base=ring.ptr, head=HEAPU32[base>>2], tail=HEAPU32[(base>>2)+1];
            if(event.type==='pointermove' && head!==tail) {
                const last=(head+ring.capacity-1)%ring.capacity;
                const lastPtr=base+8+last*ring.stride;
                if(HEAP32[lastPtr>>2]===2 && HEAP32[(lastPtr>>2)+8]===(event.pointerId||0)) {
                    pydevices_write_event(lastPtr,event); return;
                }
            }
            const recordPtr=base+8+head*ring.stride;
            if(pydevices_write_event(recordPtr,event)) {
                const next=(head+1)%ring.capacity;
                if(next===tail) HEAPU32[(base>>2)+1]=(tail+1)%ring.capacity;
                HEAPU32[base>>2]=next;
                return;
            }
        }
        const queue = display.events;
        const coalesced = event.type === 'pointermove'
            ? (candidate) => candidate.type === 'pointermove' && candidate.pointerId === event.pointerId
            : event.type === 'gamepad'
                ? (candidate) => candidate.type === 'gamepad' && candidate.index === event.index
                : null;
        if (coalesced) {
            const index = queue.findLastIndex(coalesced);
            if (index >= 0) { queue[index] = event; return; }
        }
        {
            if (queue.length >= 256) queue.shift();
            queue.push(event);
        }
    },

    $pydevices_relative_point: (canvas, event) => {
        const rect = canvas.getBoundingClientRect();
        return {
            x: Math.round((event.clientX - rect.left) * canvas.width / rect.width),
            y: Math.round((event.clientY - rect.top) * canvas.height / rect.height),
        };
    },

    $pydevices_install_input__deps: ['$pydevices_state', '$pydevices_push_event', '$pydevices_relative_point'],
    $pydevices_install_input: (canvas, canvasId) => {
        if (canvas.__pydevicesInputInstalled) return;
        canvas.__pydevicesInputInstalled = true;
        canvas.tabIndex = canvas.tabIndex >= 0 ? canvas.tabIndex : 0;
        const modifiers = (e) => ({altKey:e.altKey, ctrlKey:e.ctrlKey, metaKey:e.metaKey, shiftKey:e.shiftKey});
        for (const name of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel']) {
            canvas.addEventListener(name, (e) => {
                const p = pydevices_relative_point(canvas, e);
                pydevices_push_event(canvasId, Object.assign({type:name, x:p.x, y:p.y, movementX:e.movementX||0, movementY:e.movementY||0, button:e.button, buttons:e.buttons, pressure:e.pressure, pointerId:e.pointerId, pointerType:e.pointerType, primary:e.isPrimary}, modifiers(e)));
                if (name === 'pointerdown') {
                    canvas.focus();
                    try { canvas.setPointerCapture(e.pointerId); } catch (_) { /* Synthetic events have no active pointer. */ }
                }
                e.preventDefault();
            });
        }
        canvas.addEventListener('wheel', (e) => {
            const p = pydevices_relative_point(canvas, e);
            pydevices_push_event(canvasId, Object.assign({type:'wheel', x:p.x, y:p.y, deltaX:e.deltaX, deltaY:e.deltaY, deltaZ:e.deltaZ, deltaMode:e.deltaMode}, modifiers(e)));
            e.preventDefault();
        }, {passive:false});
        for (const name of ['keydown', 'keyup']) {
            canvas.addEventListener(name, (e) => {
                pydevices_push_event(canvasId, Object.assign({type:name, key:e.key, code:e.code, repeat:e.repeat, location:e.location}, modifiers(e)));
                if (e.key === 'Backspace' || e.key === 'Escape' || e.key === 'BrowserBack') e.preventDefault();
            });
        }
        canvas.addEventListener('focus', () => pydevices_push_event(canvasId, {type:'focus'}));
        canvas.addEventListener('blur', () => pydevices_push_event(canvasId, {type:'blur'}));
        canvas.focus();
    },

    $pydevices_paint__deps: ['$pydevices_state', '$pydevices_push_event'],
    $pydevices_paint: () => {
        const state = pydevices_state;
        let active = false;
        for (const display of state.displays.values()) {
            const fb = display.framebuffer;
            if (!fb || !display.context) continue;
            active = true;
            const src = HEAPU8.subarray(fb.ptr, fb.ptr + fb.width * fb.height * 2);
            const dst = display.image.data;
            for (let s = 0, d = 0; s < src.length; s += 2, d += 4) {
                const value = src[s] | (src[s + 1] << 8);
                dst[d] = ((value >> 11) & 31) * 255 / 31;
                dst[d + 1] = ((value >> 5) & 63) * 255 / 63;
                dst[d + 2] = (value & 31) * 255 / 31;
                dst[d + 3] = 255;
            }
            display.context.putImageData(display.image, 0, 0);
            display.framesPainted++;
        }
        if (!active) { state.animation = 0; return; }
        if (navigator.getGamepads) {
            for (const pad of navigator.getGamepads()) if (pad) {
                for (const canvasId of state.displays.keys()) {
                    pydevices_push_event(canvasId, {type:'gamepad', index:pad.index, connected:pad.connected, buttons:pad.buttons.map(b => ({pressed:b.pressed, touched:b.touched, value:b.value})), axes:Array.from(pad.axes)});
                }
                break;
            }
        }
        state.animation = requestAnimationFrame(pydevices_paint);
    },

    $pydevices_export_host__deps: ['$pydevices_state'],
    $pydevices_export_host: () => {
        if (Module.pydevicesBridge) return;
        Module.pydevicesBridge = {
            enableAudio: async (microphone=false) => {
                const state = pydevices_state;
                const AudioContext = globalThis.AudioContext || globalThis.webkitAudioContext;
                if (!AudioContext) throw new Error('Web Audio is unavailable');
                state.audioContext ||= new AudioContext();
                await state.audioContext.resume();
                state.audioEnabled = state.audioContext.state === 'running';
                if (microphone) {
                    state.mediaStream = await navigator.mediaDevices.getUserMedia({audio:true});
                    state.mediaNode = state.audioContext.createMediaStreamSource(state.mediaStream);
                    state.processor = state.audioContext.createScriptProcessor(1024, 2, 2);
                    state.processor.onaudioprocess = (event) => {
                        const channels = [];
                        for (let c = 0; c < event.inputBuffer.numberOfChannels; c++) channels.push(new Float32Array(event.inputBuffer.getChannelData(c)));
                        state.inputFrames.push({channels, rate:event.inputBuffer.sampleRate, offset:0});
                        if (state.inputFrames.length > 64) state.inputFrames.shift();
                    };
                    state.mediaNode.connect(state.processor);
                    state.processor.connect(state.audioContext.destination);
                    state.microphoneEnabled = true;
                }
                return {audio:state.audioEnabled, microphone:state.microphoneEnabled};
            },
            permissions: () => ({audio:pydevices_state.audioEnabled, microphone:pydevices_state.microphoneEnabled}),
            stats: () => ({
                events:Array.from(pydevices_state.displays.values()).reduce((n,d)=>n+d.events.length,0),
                timers:pydevices_state.timers.size,
                frames:Array.from(pydevices_state.displays.values()).reduce((n,d)=>n+d.framesPainted,0),
                queuedAudioBytes:pydevices_state.audioQueuedBytes,
                queuedAudioMs:Math.max(0, (pydevices_state.audioEnd - (pydevices_state.audioContext?.currentTime || 0)) * 1000),
                timerFirings:pydevices_state.timerFirings.slice(),
                timerDeliveries:pydevices_state.timerDeliveries.slice(),
            }),
            resetTimerFirings: () => {
                pydevices_state.timerFirings.length = 0;
                pydevices_state.timerDeliveries.length = 0;
            },
            injectMicrophone: (channels, rate=48000) => {
                pydevices_state.microphoneEnabled = true;
                pydevices_state.inputFrames.push({channels:channels.map(x => Float32Array.from(x)), rate, offset:0});
            },
        };
    },

    pydevices_display_register__deps: ['$pydevices_get_display', '$pydevices_install_input', '$pydevices_paint', '$pydevices_export_host'],
    pydevices_display_register: (ptr, len, width, height, canvasPtr) => {
        if (typeof document === 'undefined') return 0;
        const canvasId = UTF8ToString(canvasPtr);
        const canvas = document.getElementById(canvasId);
        if (!canvas) return 0;
        canvas.width = width; canvas.height = height;
        const context = canvas.getContext('2d', {alpha:false});
        const display = pydevices_get_display(canvasId);
        display.framebuffer = {ptr, len, width, height};
        display.canvas = canvas;
        display.context = context;
        display.image = context.createImageData(width, height);
        display.framesPainted = 0;
        pydevices_install_input(canvas, canvasId);
        pydevices_export_host();
        if (!pydevices_state.animation) pydevices_state.animation = requestAnimationFrame(pydevices_paint);
        return 1;
    },

    pydevices_display_unregister__deps: ['$pydevices_state'],
    pydevices_display_unregister: (canvasPtr) => {
        pydevices_state.displays.delete(UTF8ToString(canvasPtr));
    },

    pydevices_event_poll__deps: ['$pydevices_get_display'],
    pydevices_event_poll: (canvasPtr, lenPtr) => {
        const display = pydevices_get_display(UTF8ToString(canvasPtr));
        if (!display.events.length) return 0;
        const text = JSON.stringify(display.events.shift());
        const len = lengthBytesUTF8(text);
        const ptr = _malloc(len + 1);
        stringToUTF8(text, ptr, len + 1);
        HEAPU32[lenPtr >> 2] = len;
        return ptr;
    },
    pydevices_event_set_buffer__deps: ['$pydevices_get_display'],
    pydevices_event_set_buffer: (canvasPtr, ptr, capacity, stride) => {
        pydevices_get_display(UTF8ToString(canvasPtr)).eventRing = ptr ? {ptr,capacity,stride} : null;
    },
    pydevices_event_clear__deps: ['$pydevices_get_display'],
    pydevices_event_clear: (canvasPtr) => {
        const display = pydevices_get_display(UTF8ToString(canvasPtr));
        display.events.length = 0;
        const ring = display.eventRing;
        if(ring) { HEAPU32[ring.ptr>>2]=0; HEAPU32[(ring.ptr>>2)+1]=0; }
    },

    pydevices_host_reset__deps: ['$pydevices_state'],
    pydevices_host_reset: () => {
        const state = pydevices_state;
        state.displays.clear();
        state.firedTimers.length = 0;
        for (const timer of state.timers.values()) {
            timer.periodic ? clearInterval(timer.handle) : clearTimeout(timer.handle);
        }
        state.timers.clear();
        for (const source of state.audioSources) source.stop();
        state.audioSources.clear();
        state.audioQueuedBytes = 0;
        state.audioEnd = state.audioContext?.currentTime || 0;
        state.inputFrames.length = 0;
    },

    pydevices_timer_start__deps: ['$pydevices_state'],
    pydevices_timer_start: (id, delay, periodic) => {
        const state = pydevices_state;
        const old = state.timers.get(id); if (old) clearTimeout(old.handle);
        const fire = () => {
            state.timerFirings.push({id, at:performance.now()});
            if (state.timerFirings.length > 512) state.timerFirings.shift();
            if((typeof Asyncify==='undefined' || !Asyncify.currData) && Module._pydevices_timer_dispatch) {
                Module._pydevices_timer_dispatch(id);
                state.timerDeliveries.push({id, at:performance.now()});
                if (state.timerDeliveries.length > 512) state.timerDeliveries.shift();
            } else if (state.firedTimers.length < 256) {
                state.firedTimers.push(id);
            }
            if (!periodic) state.timers.delete(id);
        };
        const handle = periodic ? setInterval(fire, delay) : setTimeout(fire, delay);
        state.timers.set(id, {handle, periodic});
    },
    pydevices_timer_cancel__deps: ['$pydevices_state'],
    pydevices_timer_cancel: (id) => { const t=pydevices_state.timers.get(id); if (t) { t.periodic ? clearInterval(t.handle) : clearTimeout(t.handle); pydevices_state.timers.delete(id); } },
    pydevices_timer_poll__deps: ['$pydevices_state'],
    pydevices_timer_poll: () => pydevices_state.firedTimers.length ? pydevices_state.firedTimers.shift() : -1,

    pydevices_audio_state__deps: ['$pydevices_state'],
    pydevices_audio_state: (input) => input ? +pydevices_state.microphoneEnabled : +pydevices_state.audioEnabled,

    $pydevices_decode_pcm: (bytes, frames, channels, bits, signed, bigEndian) => {
        const result = Array.from({length:channels}, () => new Float32Array(frames));
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const width = bits >> 3, little = !bigEndian;
        for (let f=0; f<frames; f++) for (let c=0; c<channels; c++) {
            const p=(f*channels+c)*width; let v;
            if (bits===8) v=signed?view.getInt8(p):view.getUint8(p)-128;
            else if (bits===16) v=signed?view.getInt16(p,little):view.getUint16(p,little)-32768;
            else v=signed?view.getInt32(p,little):view.getUint32(p,little)-2147483648;
            result[c][f] = v / (bits===8?128:bits===16?32768:2147483648);
        }
        return result;
    },

    pydevices_audio_write__deps: ['$pydevices_state', '$pydevices_decode_pcm'],
    pydevices_audio_write: (ptr, len, rate, channels, bits, signed, bigEndian) => {
        const state=pydevices_state, ctx=state.audioContext;
        if (!state.audioEnabled || !ctx) return -1;
        const width=bits>>3, frames=Math.floor(len/(width*channels));
        const decoded=pydevices_decode_pcm(HEAPU8.subarray(ptr, ptr+frames*width*channels),frames,channels,bits,signed,bigEndian);
        const buffer=ctx.createBuffer(channels,frames,rate);
        for(let c=0;c<channels;c++) buffer.copyToChannel(decoded[c],c);
        const source=ctx.createBufferSource(); source.buffer=buffer; source.connect(ctx.destination);
        const start=Math.max(ctx.currentTime,state.audioEnd); state.audioEnd=start+frames/rate;
        const byteLength=frames*width*channels;
        state.audioQueuedBytes += byteLength;
        state.audioSources.add(source);
        source.onended=()=>{
            if(state.audioSources.delete(source)) state.audioQueuedBytes=Math.max(0,state.audioQueuedBytes-byteLength);
        };
        source.start(start);
        return byteLength;
    },

    $pydevices_encode_sample: (view, p, value, bits, signed, bigEndian) => {
        const little=!bigEndian, clamped=Math.max(-1,Math.min(1,value));
        if(bits===8) signed?view.setInt8(p,Math.round(clamped*127)):view.setUint8(p,Math.round((clamped+1)*127.5));
        else if(bits===16) signed?view.setInt16(p,Math.round(clamped*32767),little):view.setUint16(p,Math.round((clamped+1)*32767.5),little);
        else signed?view.setInt32(p,Math.round(clamped*2147483647),little):view.setUint32(p,Math.round((clamped+1)*2147483647.5),little);
    },

    pydevices_audio_read__deps: ['$pydevices_state', '$pydevices_encode_sample'],
    pydevices_audio_read: (ptr, len, rate, channels, bits, signed, bigEndian) => {
        const state=pydevices_state; if(!state.microphoneEnabled) return -1;
        const width=bits>>3, capacity=Math.floor(len/(width*channels)); let written=0;
        const view=new DataView(HEAPU8.buffer,ptr,len);
        while(written<capacity && state.inputFrames.length){
            const frame=state.inputFrames[0];
            while(written<capacity && frame.offset<frame.channels[0].length){
                const sourceIndex=Math.min(frame.channels[0].length-1,Math.floor(frame.offset));
                for(let c=0;c<channels;c++) pydevices_encode_sample(view,(written*channels+c)*width,frame.channels[Math.min(c,frame.channels.length-1)][sourceIndex],bits,signed,bigEndian);
                written++; frame.offset += frame.rate/rate;
            }
            if(frame.offset>=frame.channels[0].length) state.inputFrames.shift();
        }
        return written*channels*width;
    },

    pydevices_audio_clear__deps: ['$pydevices_state'],
    pydevices_audio_clear: (input) => { const s=pydevices_state; if(input)s.inputFrames.length=0; else { for(const x of s.audioSources)x.stop(); s.audioSources.clear(); s.audioQueuedBytes=0; s.audioEnd=s.audioContext?.currentTime||0; } },
    pydevices_audio_queued__deps: ['$pydevices_state'],
    pydevices_audio_queued: (input) => input ? pydevices_state.inputFrames.reduce((n,f)=>n+(f.channels[0].length-f.offset)*f.channels.length*4,0) : pydevices_state.audioQueuedBytes,

    pydevices_http_get__deps: ['$Asyncify'],
    pydevices_http_get: (urlPtr, statusPtr, lenPtr, finalUrlPtr) => Asyncify.handleSleep(async (wakeUp) => {
        try {
            const response=await fetch(UTF8ToString(urlPtr)); const bytes=new Uint8Array(await response.arrayBuffer());
            const ptr=_malloc(bytes.length || 1); HEAPU8.set(bytes,ptr);
            const urlLen=lengthBytesUTF8(response.url), outUrl=_malloc(urlLen+1); stringToUTF8(response.url,outUrl,urlLen+1);
            HEAP32[statusPtr>>2]=response.status; HEAPU32[lenPtr>>2]=bytes.length; HEAPU32[finalUrlPtr>>2]=outUrl; wakeUp(ptr);
        } catch(error) {
            console.error('PyDevices Fetch failed',error); HEAP32[statusPtr>>2]=0; HEAPU32[lenPtr>>2]=0; HEAPU32[finalUrlPtr>>2]=0; wakeUp(0);
        }
    }),
    pydevices_sleep_ms__deps: ['$Asyncify'],
    pydevices_sleep_ms: (ms) => Asyncify.handleSleep((wakeUp) => setTimeout(wakeUp, Math.max(0, ms))),
});
