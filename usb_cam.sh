#!/bin/bash

# USB Camera Streaming Script for RPi_Cam_Web_Interface
# Uses ffmpeg to capture from a USB/V4L2 camera device and update
# /dev/shm/mjpeg/cam.jpg so the existing cam_pic.php preview works unchanged.
#
# Commands (passed as first argument):
#   start         - start preview streaming
#   stop          - stop all usb_cam processes
#   capture_image - save current frame to media directory
#   start_video   - start video recording
#   stop_video    - stop video recording
#   restart       - stop then start

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
cd "$SCRIPT_DIR"

source ./config.txt

USB_DEVICE="${usb_cam_device:-/dev/video0}"
USB_WIDTH="${usb_cam_width:-640}"
USB_HEIGHT="${usb_cam_height:-480}"
USB_FPS="${usb_cam_fps:-15}"
SHM_DIR="/dev/shm/mjpeg"
PREVIEW_PID_FILE="$SHM_DIR/usb_cam_preview.pid"
VIDEO_PID_FILE="$SHM_DIR/usb_cam_video.pid"
STATUS_FILE="$SHM_DIR/status_mjpeg.txt"
PREVIEW_LOG="$SHM_DIR/usb_cam_preview.log"

# rpicamdir in config.txt has no leading slash; add it only if non-empty
if [ -n "$rpicamdir" ]; then
   MEDIA_DIR="/var/www/${rpicamdir}/media"
else
   MEDIA_DIR="/var/www/media"
fi

log() {
    echo "[$(date '+%Y/%m/%d %H:%M:%S')] [usb_cam] $*" >> "${MEDIA_DIR}/../scheduleLog.txt" 2>/dev/null || true
}

stop_preview() {
    if [ -f "$PREVIEW_PID_FILE" ]; then
        kill "$(cat "$PREVIEW_PID_FILE")" 2>/dev/null
        rm -f "$PREVIEW_PID_FILE"
    fi
    # Kill any leftover ffmpeg reading this device for preview
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

start_preview() {
    stop_preview

    mkdir -p "$SHM_DIR"
    chown www-data:www-data "$SHM_DIR" 2>/dev/null || true
    chmod 777 "$SHM_DIR"

    log "Starting USB camera preview on $USB_DEVICE at ${USB_WIDTH}x${USB_HEIGHT} @ ${USB_FPS}fps"

    # Build ffmpeg args: try MJPEG input first (best for USB webcams),
    # fall back to raw V4L2 if the device doesn't support MJPEG.
    if v4l2-ctl --device="$USB_DEVICE" --list-formats 2>/dev/null | grep -qi "mjpeg\|mjpg"; then
        INPUT_ARGS=(-f v4l2 -input_format mjpeg -video_size "${USB_WIDTH}x${USB_HEIGHT}" -framerate "$USB_FPS" -i "$USB_DEVICE")
        log "Camera supports MJPEG input format"
    else
        INPUT_ARGS=(-f v4l2 -video_size "${USB_WIDTH}x${USB_HEIGHT}" -framerate "$USB_FPS" -i "$USB_DEVICE")
        log "Using raw V4L2 input format"
    fi

    # Output: update cam.jpg at ~5fps continuously
    ffmpeg "${INPUT_ARGS[@]}" \
        -vf "fps=fps=5" \
        -q:v 5 \
        -update 1 \
        -f image2 \
        "$SHM_DIR/cam.jpg" \
        > "$PREVIEW_LOG" 2>&1 &

    FFMPEG_PID=$!
    echo "$FFMPEG_PID" > "$PREVIEW_PID_FILE"
    log "Preview started (PID $FFMPEG_PID)"

    # Wait up to 5 seconds for the first frame
    for i in $(seq 1 10); do
        sleep 0.5
        if [ -s "$SHM_DIR/cam.jpg" ]; then
            log "First frame captured successfully"
            echo "ready" > "$STATUS_FILE"
            return 0
        fi
        # Check if ffmpeg already died
        if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
            log "ffmpeg exited early. Last output:"
            tail -20 "$PREVIEW_LOG" >> "${MEDIA_DIR}/../scheduleLog.txt" 2>/dev/null || true
            # Try without specifying resolution as last resort
            log "Retrying with auto resolution..."
            ffmpeg -f v4l2 -i "$USB_DEVICE" \
                -vf "fps=fps=5" \
                -q:v 5 \
                -update 1 \
                -f image2 \
                "$SHM_DIR/cam.jpg" \
                > "$PREVIEW_LOG" 2>&1 &
            FFMPEG_PID=$!
            echo "$FFMPEG_PID" > "$PREVIEW_PID_FILE"
            log "Fallback preview started (PID $FFMPEG_PID)"
            sleep 2
            break
        fi
    done

    if [ -s "$SHM_DIR/cam.jpg" ]; then
        echo "ready" > "$STATUS_FILE"
        log "Preview running"
    else
        log "Warning: cam.jpg not yet created; ffmpeg may still be initialising"
        echo "ready" > "$STATUS_FILE"
    fi
}

capture_image() {
    mkdir -p "$MEDIA_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    COUNT=$(printf "%04d" $(( $(ls "$MEDIA_DIR"/im_*.jpg 2>/dev/null | wc -l) + 1 )))
    OUTFILE="$MEDIA_DIR/im_${COUNT}_${TIMESTAMP}.jpg"

    log "Capturing image to $OUTFILE"

    ffmpeg -f v4l2 \
        -video_size "${USB_WIDTH}x${USB_HEIGHT}" \
        -i "$USB_DEVICE" \
        -vframes 1 \
        -q:v 2 \
        "$OUTFILE" \
        > /dev/null 2>&1

    if [ -s "$OUTFILE" ]; then
        log "Image saved: $OUTFILE"
    else
        # Fallback: copy current preview frame
        if [ -s "$SHM_DIR/cam.jpg" ]; then
            cp "$SHM_DIR/cam.jpg" "$OUTFILE"
            log "Image captured from preview frame: $OUTFILE"
        else
            log "Image capture failed"
        fi
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
        -video_size "${USB_WIDTH}x${USB_HEIGHT}" \
        -framerate "$USB_FPS" \
        -i "$USB_DEVICE" \
        -c:v libx264 \
        -preset ultrafast \
        -pix_fmt yuv420p \
        "$OUTFILE" \
        > "$SHM_DIR/usb_cam_video.log" 2>&1 &

    echo $! > "$VIDEO_PID_FILE"
    echo "video $OUTFILE" > "$STATUS_FILE"
    log "Video recording started (PID $(cat "$VIDEO_PID_FILE"))"
}

case "${1:-start}" in
    start)
        start_preview
        ;;
    stop)
        stop_preview
        stop_video_proc
        echo "halted" > "$STATUS_FILE"
        log "USB camera stopped"
        ;;
    capture_image)
        capture_image
        ;;
    start_video)
        start_video_recording
        ;;
    stop_video)
        stop_video_proc
        echo "ready" > "$STATUS_FILE"
        ;;
    restart)
        stop_preview
        stop_video_proc
        sleep 1
        start_preview
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|capture_image|start_video|stop_video}"
        exit 1
        ;;
esac
