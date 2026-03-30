import 'dart:io';
import 'dart:convert'; // Added to support utf8.decode
import 'package:dartssh2/dartssh2.dart';

void main() async {
  final socket = await SSHSocket.connect('srv-cad.ece.mcmaster.ca', 22);
  
  final client = SSHClient(
    socket,
    username: 'let36',
    onPasswordRequest: () => '400385350', // Consider using SSH keys in the future for security!
  );

  try {
    // Chain the commands: navigate, activate conda, then run sbatch
    final command = 'cd /home/let36/capstone/scripts && conda activate sam3 && sbatch run_script.sh';
    
    // Submit the job to Slurm
    final result = await client.run(command);
    final output = utf8.decode(result).trim();

    print(output); // Example: "Submitted batch job 123456"

    // Extracting Job ID for tracking
    final jobId = output.split(' ').last;
    print('Job successfully submitted with ID: $jobId');

  } catch (e) {
    print('An error occurred: $e');
  } finally {
    // It's good practice to close the client when you're done
    client.close(); 
  }
}