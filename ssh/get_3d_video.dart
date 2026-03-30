import 'dart:io';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'dart:typed_data';

void main() async {
  // connect to McMaster ECE server
  final socket = await SSHSocket.connect('srv-cad.ece.mcmaster.ca', 22);
  // login with username and password (when can try using SSH keys for better security)
  final client = SSHClient(
    socket,
    username: 'let36',
    onPasswordRequest: () => '400385350',
  );
  // try submitting the job to Slurm using sbatch, which runs our python script for generate the 3D video
  try {
    // !!! set local_path to the path of the CSV file that we want to transferred to the server and want to process
    
    // define the path of the CSV file that we want to send to the server
    final local_path = "imu-datasets/cleaned_water_datasets/rand_10.csv"; // copy the relative path, and use '/' instead of '\'
    // extract the file name
    final String file_name = local_path.split('/').last;
    // set the destination path on the server after sending
    final String imu_path = '/home/let36/capstone/data/$file_name';
    // send the CSV file that we want to process to the server using SFTP
    final sftp = await client.sftp();
    final local_file = File(local_path);
    if (!await local_file.exists()) {
      throw Exception("Local file not found at $local_path");
    }
    // Open remote file (creates if missing, overwrites if existing)
    final remote_file = await sftp.open(
      imu_path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    // Stream the local file data to the remote server
    await remote_file.write(local_file.openRead().cast<Uint8List>());
    // close the SFTP file when done
    await remote_file.close();
    print('File transferred successfully to $imu_path');

    // change directory to where our .sh script is, activate conda, then run sbatch while passing the imu_path as an argument to the .sh script, which will then pass it to the python script
    final command = 'cd /home/let36/capstone/scripts && conda activate sam3 && sbatch run_script.sh $imu_path';
    // submit the job to Slurm
    final result = await client.run(command);
    final output = utf8.decode(result).trim();
    // print the output to manually confirm that the job was submitted
    print(output);
    // Extracting the job ID
    final job_id = output.split(' ').last;
    print('Submitted job ID: $job_id');

    // monitor our job status using squeue until it is completed
    bool in_queue = true;
    print('Monitoring Job ID: $job_id via squeue...');

    while (in_queue) {
        // wait for 2 seconds before checking again
        await Future.delayed(Duration(seconds: 2));

        // Run squeue for your specific Job ID
        // -h removes the header, -j filters by ID, -t specifies states (optional)
        final check = await client.run('squeue -h -j $job_id');
        final status = utf8.decode(check).trim();

        if (status.isEmpty) {
            // If squeue returns nothing, the job is no longer Pending or Running
            print('Job $job_id is no longer in the queue. (Finished)');
            in_queue = false;
        } else {
            // status will contain a line like: "123456  debug  run_script  let36  R  0:01  1  node01"
            // We can parse the 'R' (Running) or 'PD' (Pending) if we want to be fancy
            print('Job status: $status');
        }
    }

    // once the job is done, we want to transfer back the 3D videos

    // Create a local directory for outputs if it doesn't exist
    final local_out_folder = Directory('outputs');
    if (!await local_out_folder.exists()) {
      await local_out_folder.create();
    }

    // our server's python script saves the outputs to this folder
    final String remote_folder = '/home/let36/capstone/scripts/outputs';

    // get the file name without extension
    final String base_name = file_name.split('.').first;

    for (int i = 1; i <= 5; i++) {
      final String video_name = '${base_name}_view$i.mp4';
      final String remote_video_path = '$remote_folder/$video_name';
      final String local_video_path = 'outputs/$video_name';

      try {
        print('Downloading $video_name...');
        final remote_file = await sftp.open(remote_video_path);
        final local_file = File(local_video_path).openWrite();
        
        // Read from remote and pipe to local file
        await local_file.addStream(remote_file.read());
        
        await local_file.close();
        print('Videos saved to $local_video_path');
      } catch (e) {
        print('Could not find or download $video_name: $e');
      }
    }
    print('Completed.');

  } catch (e) {
    print('An error occurred: $e');
  } finally {
    client.close(); 
  }
}