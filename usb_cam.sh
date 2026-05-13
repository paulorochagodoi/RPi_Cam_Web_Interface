#!/bin/bash

# USB Camera Streaming Script for RPi_Cam_Web_Interface
# Uses ffmpeg to capture from a USB/V4L2 camera device and update
# /dev/shm/mjpeg/cam.jpg so the existing cam_pic.php preview works unchanged.

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
cd "$SCRIPT_DIR"

# config.txt lives next to this script in the project dir.
# When installed via a wrapper at /usr/local/bin, SCRIPT_DIR may point
# there; fall back to the path stored by the installer.
if [ -f "$SCRIPT_DIR/config.txt" ]; then
   source "$SCRIPT_DIR/config.txt"
elif [ -f "/etc/rpi_cam_web_interface/config.txt" ]; then
   source "/etc/rpi_cam_web_interface/config.txt"
else
   echo "[usb_cam] ERROR: config.txt not found" >&2
   exit 1
fi

USB_DEVICE="${usb_cam_device:-/dev/video0}"
USB_WIDTH="${usb_cam_width:-640}"
USB_HEIGHT="${usb_cam_height:-480}"
USB_FPS="${usb_cam_fps:-15}"
SHM_DIR="/dev/shm/mjpeg"
PREVIEW_PID_FILE="$SHM_DIR/usb_cam_preview.pid"
VIDEO_PID_FILE="$SHM_DIR/usb_cam_video.pid"
STATUS_FILE="$SHM_DIR/status_mjpeg.txt"
PREVIEW_LOG="$SHM_DIR/usb_cam_preview.log"

if [ -n "$rpicamdir" ]; then
   WEB_DIR="/var/www/${rpicamdir}"
else
   WEB_DIR="/var/www"
fi
MEDIA_DIR="${WEB_DIR}/media"
LOG_FILE="${WEB_DIR}/scheduleLog.txt"

log() {
    echo "[$(date '+%Y/%m/%d %H:%M:%S')] [usb_cam] $*" >> "$LOG_FILE" 2>/dev/null || true
}

stop_preview() {
    if [ -f "$PREVIEW_PID_FILE" ]; then
        kill "$(cat "$PREVIEW_PID_FILE")" 2>/dev/null
        rm -f "$PREVIEW_PID_FILE"
    fi
    pkill -f "ffmpeg.*${USB_DEVICE}.*cam\.jpg" 2>/dev/null
    sleep 0.5
}

stop_video_proc() {
    if [ -f "$VIDEO_PID_FILE" ]; then
        kill "$(cat "$VIDEO_PID_FILE")" 2>/dev/null
        rm -f "$VIDEO_PID_FILE"
    fi
    pkill -f "ffmpeg.*${USB_DEVICE}.*vi_" 2>/dev/null
}

try_ffmpeg() {
    # Try a specific ffmpeg command; return 0 if cam.jpg is created within 4s
    log "Trying: ffmpeg $*"
    ffmpeg "$@" > "$PREVIEW_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$PREVIEW_PID_FILE"

    for i in $(seq 1 8); do
        sleep 0.5
        if [ -s "$SHM_DIR/cam.jpg" ]; then
            log "Success (PID $pid)"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            log "ffmpeg (PID $pid) exited early"
            rm -f "$PREVIEW_PID_FILE"
            return 1
        fi
    done

    # Still running but no frame yet — kill and report failure
    kill "$pid" 2>/dev/null
    rm -f "$PREVIEW_PID_FILE"
    log "Timeout waiting for first frame"
    return 1
}

start_preview() {
    stop_preview

    mkdir -p "$SHM_DIR"
    chown www-data:www-data "$SHM_DIR" 2>/dev/null || true
    chmod 777 "$SHM_DIR"

    if [ ! -e "$USB_DEVICE" ]; then
        log "ERROR: device $USB_DEVICE not found"
        echo "halted" > "$STATUS_FILE"
        return 1
    fi

    log "Starting preview on $USB_DEVICE (${USB_WIDTH}x${USB_HEIGHT} @ ${USB_FPS}fps)"

    OUTPUT_ARGS=(-vf "fps=fps=5" -q:v 5 -update 1 -f image2 "$SHM_DIR/cam.jpg")

    # Strategy 1: MJPEG input at requested resolution
    if v4l2-ctl --device="$USB_DEVICE" --list-formats 2>/dev/null | grep -qi "mjpeg\|mjpg"; then
        log "Camera supports MJPEG"
        try_ffmpeg -f v4l2 -input_format mjpeg \
            -video_size "${USB_WIDTH}x${USB_HEIGHT}" -framerate "$USB_FPS" \
            -i "$USB_DEVICE" "${OUTPUT_ARGS[@]}" && { echo "ready" > "$STATUS_FILE"; return 0; }
    fi

    # Strategy 2: YUYV at requested resolution
    log "Trying YUYV at ${USB_WIDTH}x${USB_HEIGHT}"
    try_ffmpeg -f v4l2 \
        -video_size "${USB_WIDTH}x${USB_HEIGHT}" -framerate "$USB_FPS" \
        -i "$USB_DEVICE" "${OUTPUT_ARGS[@]}" && { echo "ready" > "$STATUS_FILE"; return 0; }

    # Strategy 3: MJPEG without specifying resolution (let camera decide)
    if v4l2-ctl --device="$USB_DEVICE" --list-formats 2>/dev/null | grep -qi "mjpeg\|mjpg"; then
        log "Trying MJPEG with auto resolution"
        try_ffmpeg -f v4l2 -input_format mjpeg \
            -i "$USB_DEVICE" "${OUTPUT_ARGS[@]}" && { echo "ready" > "$STATUS_FILE"; return 0; }
    fi

    # Strategy 4: Fully auto — let ffmpeg negotiate everything
    log "Trying fully automatic format negotiation"
    try_ffmpeg -f v4l2 -i "$USB_DEVICE" "${OUTPUT_ARGS[@]}" && { echo "ready" > "$STATUS_FILE"; return 0; }

    log "ERROR: All strategies failed. Check $PREVIEW_LOG for details."
    log "Available formats on $USB_DEVICE:"
    v4l2-ctl --device="$USB_DEVICE" --list-formats-ext 2>&1 | tee -a "$LOG_FILE" || true
    echo "halted" > "$STATUS_FILE"
    return 1
}

capture_image() {
    mkdir -p "$MEDIA_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    COUNT=$(printf "%04d" $(( $(ls "$MEDIA_DIR"/im_*.jpg 2>/dev/null | wc -l) + 1 )))
    OUTFILE="$MEDIA_DIR/im_${COUNT}_${TIMESTAMP}.jpg"
    log "Capturing image to $OUTFILE"

    ffmpeg -f v4l2 -video_size "${USB_WIDTH}x${USB_HEIGHT}" \
        -i "$USB_DEVICE" -vframes 1 -q:v 2 "$OUTFILE" > /dev/null 2>&1

    if [ ! -s "$OUTFILE" ] && [ -s "$SHM_DIR/cam.jpg" ]; then
        cp "$SHM_DIR/cam.jpg" "$OUTFILE"
        log "Captured from preview frame: $OUTFILE"
    elif [ -s "$OUTFILE" ]; then
        log "Image saved: $OUTFILE"
    else
        log "Image capture failed"
    fi
}

start_video_recording() {
    stop_video_proc
    mkdir -p "$MEDIA_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    COUNT=$(printf "%04d" $(( $(ls "$MEDIA_DIR"/vi_*.mp4 2>/dev/null | wc -l) + 1 )))
    OUTFILE="$MEDIA_DIR/vi_${COUNT}_${TIMESTAMP}.mp4"
    log "Starting video recording to $OUTFILE"

    ffmpeg -f v4l2 \
        -video_size "${USB_WIDTH}x${USB_HEIGHT}" -framerate "$USB_FPS" \
        -i "$USB_DEVICE" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        "$OUTFILE" > "$SHM_DIR/usb_cam_video.log" 2>&1 &

    echo $! > "$VIDEO_PID_FILE"
    echo "video $OUTFILE" > "$STATUS_FILE"
    log "Video recording started (PID $(cat "$VIDEO_PID_FILE"))"
}

case "${1:-start}" in
    start)   start_preview ;;
    stop)
        stop_preview; stop_video_proc
        echo "halted" > "$STATUS_FILE"
        log "USB camera stopped"
        ;;
    capture_image) capture_image ;;
    start_video)   start_video_recording ;;
    stop_video)
        stop_video_proc
        echo "ready" > "$STATUS_FILE"
        ;;
    restart)
        stop_preview; stop_video_proc
        sleep 1
        start_preview
        ;;
    log)
        cat "$PREVIEW_LOG" 2>/dev/null || echo "No log available"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|capture_image|start_video|stop_video|log}"
        exit 1
        ;;
esac
