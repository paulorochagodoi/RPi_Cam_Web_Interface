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

cd "$(dirname "$(readlink -f "$0")")"

source ./config.txt

USB_DEVICE="${usb_cam_device:-/dev/video0}"
USB_WIDTH="${usb_cam_width:-640}"
USB_HEIGHT="${usb_cam_height:-480}"
USB_FPS="${usb_cam_fps:-15}"
MEDIA_DIR="/var/www/${rpicamdir}/media"
SHM_DIR="/dev/shm/mjpeg"
PREVIEW_PID_FILE="$SHM_DIR/usb_cam_preview.pid"
VIDEO_PID_FILE="$SHM_DIR/usb_cam_video.pid"
STATUS_FILE="$SHM_DIR/status_mjpeg.txt"

log() {
    echo "[usb_cam] $*" >> /var/www/${rpicamdir}/scheduleLog.txt
}

stop_preview() {
    if [ -f "$PREVIEW_PID_FILE" ]; then
        kill "$(cat "$PREVIEW_PID_FILE")" 2>/dev/null
        rm -f "$PREVIEW_PID_FILE"
    fi
    pkill -f "ffmpeg.*$USB_DEVICE.*cam.jpg" 2>/dev/null
}

stop_video() {
    if [ -f "$VIDEO_PID_FILE" ]; then
        kill "$(cat "$VIDEO_PID_FILE")" 2>/dev/null
        rm -f "$VIDEO_PID_FILE"
    fi
    pkill -f "ffmpeg.*$USB_DEVICE.*vi_" 2>/dev/null
    echo "halted" > "$STATUS_FILE"
}

start_preview() {
    stop_preview

    mkdir -p "$SHM_DIR"
    chown www-data:www-data "$SHM_DIR" 2>/dev/null
    chmod 777 "$SHM_DIR"

    log "Starting USB camera preview on $USB_DEVICE at ${USB_WIDTH}x${USB_HEIGHT}@${USB_FPS}fps"

    # Try MJPEG input first (most USB cameras support it natively)
    if v4l2-ctl --device="$USB_DEVICE" --list-formats 2>/dev/null | grep -q MJPG; then
        ffmpeg -f v4l2 \
            -input_format mjpeg \
            -video_size "${USB_WIDTH}x${USB_HEIGHT}" \
            -framerate "$USB_FPS" \
            -i "$USB_DEVICE" \
            -vf "fps=fps=5" \
            -q:v 5 \
            -update 1 \
            -f image2 \
            "$SHM_DIR/cam.jpg" \
            > "$SHM_DIR/usb_cam_preview.log" 2>&1 &
    else
        ffmpeg -f v4l2 \
            -video_size "${USB_WIDTH}x${USB_HEIGHT}" \
            -framerate "$USB_FPS" \
            -i "$USB_DEVICE" \
            -vf "fps=fps=5" \
            -q:v 5 \
            -update 1 \
            -f image2 \
            "$SHM_DIR/cam.jpg" \
            > "$SHM_DIR/usb_cam_preview.log" 2>&1 &
    fi

    echo $! > "$PREVIEW_PID_FILE"
    echo "ready" > "$STATUS_FILE"
    log "Preview PID: $(cat "$PREVIEW_PID_FILE")"
}

capture_image() {
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    COUNT=$(ls "$MEDIA_DIR"/im_*.jpg 2>/dev/null | wc -l)
    COUNT=$(printf "%04d" $((COUNT + 1)))
    OUTFILE="$MEDIA_DIR/im_${COUNT}_${TIMESTAMP}.jpg"

    log "Capturing image to $OUTFILE"

    ffmpeg -f v4l2 \
        -video_size "${USB_WIDTH}x${USB_HEIGHT}" \
        -i "$USB_DEVICE" \
        -vframes 1 \
        -q:v 2 \
        "$OUTFILE" \
        > /dev/null 2>&1

    if [ -f "$OUTFILE" ]; then
        log "Image saved: $OUTFILE"
    else
        log "Image capture failed"
    fi
}

start_video_recording() {
    stop_video

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    COUNT=$(ls "$MEDIA_DIR"/vi_*.mp4 2>/dev/null | wc -l)
    COUNT=$(printf "%04d" $((COUNT + 1)))
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
    log "Video recording PID: $(cat "$VIDEO_PID_FILE")"
}

case "${1:-start}" in
    start)
        start_preview
        ;;
    stop)
        stop_preview
        stop_video
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
        stop_video
        ;;
    restart)
        stop_preview
        stop_video
        sleep 1
        start_preview
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|capture_image|start_video|stop_video}"
        exit 1
        ;;
esac
