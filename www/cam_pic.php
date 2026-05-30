<?php
  header("Access-Control-Allow-Origin: *");
  header("Content-Type: image/jpeg");
   if (isset($_GET["pDelay"]))
   {
      $preview_delay = $_GET["pDelay"];
   } else {
      $preview_delay = 10000;
   }
   usleep($preview_delay);
   $cam_jpg = "/dev/shm/mjpeg/cam.jpg";
   if (file_exists($cam_jpg) && filesize($cam_jpg) > 0) {
      readfile($cam_jpg);
   } else {
      readfile(dirname(__FILE__) . "/loading.jpg");
   }

?>
