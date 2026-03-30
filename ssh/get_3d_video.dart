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
    final String fileName = local_path.split('/').last;
    // set the destination path on the server after sending
    final String imu_path = '/home/let36/capstone/data/$fileName';
    // send the CSV file that we want to process to the server using SFTP
    final sftp = await client.sftp();
    final local_file = File(local_path);
    if (!await local_file.exists()) {
      throw Exception("Local file not found at $local_path");
    }
    // Open remote file (creates if missing, overwrites if existing)
    final remoteFile = await sftp.open(
      imu_path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    // Stream the local file data to the remote server
    await remoteFile.write(local_file.openRead().cast<Uint8List>());
    // close the SFTP file when done
    await remoteFile.close();
    print('File transferred successfully to $imu_path');

    // change directory to where our .sh script is, activate conda, then run sbatch while passing the imu_path as an argument to the .sh script, which will then pass it to the python script
    final command = 'cd /home/let36/capstone/scripts && conda activate sam3 && sbatch run_script.sh $imu_path';
    // submit the job to Slurm
    final result = await client.run(command);
    final output = utf8.decode(result).trim();
    // print the output to manually confirm that the job was submitted
    print(output);
    // Extracting the job ID
    final jobId = output.split(' ').last;
    print('Submitted job ID: $jobId');

  } catch (e) {
    print('An error occurred: $e');
  } finally {
    client.close(); 
  }
}