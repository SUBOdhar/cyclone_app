// lib/services/file_service.dart

import 'dart:async';
import 'dart:io';
import 'package:cyclone_app/services/device_info.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class FileService {
  final http.Client _httpClient = http.Client();
  String _baseUrl;
  final BuildContext context;

  FileService(this._baseUrl, this.context);

  Future<void> dispose() async {
    _httpClient.close();
  }

  Future<void> handelFolderCreate(List folderPath, String folderName) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final accessToken = prefs.getString('accessToken');
    final storageServer = prefs.getString('storage_server');

    try {
      final request =
          http.Request('POST', Uri.parse('$storageServer/api/create-folder'));
      request.headers.addAll({
        'Content-Type': 'application/json; charset=UTF-8',
      });
      request.body = jsonEncode({
        'owner_id': userId,
        'device_name': await getDeviceName(),
        'currentFolder': folderPath.join('/'),
        'newFolder': folderName,
        'accessToken': accessToken
      });

      final http.StreamedResponse response = await _httpClient.send(request);
      final int statusCode = response.statusCode;

      if (statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Folder Created successfully')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Folder was not created')),
        );
      }
    } catch (e) {
      print(e);
    }
  }

  Future<void> handleShare(int id) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final accessToken = prefs.getString('accessToken');

    final storageServer = prefs.getString('storage_server');
    if (storageServer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Storage server not configured')),
      );
      return;
    }
    _baseUrl = storageServer;

    try {
      final request = http.Request('POST', Uri.parse('$storageServer/gsl'));
      request.headers.addAll({
        'Content-Type': 'application/json; charset=UTF-8',
      });
      request.body = jsonEncode({
        'fileId': id,
        'owner_id': userId,
        'assessToken': accessToken,
        'device_name': await getDeviceName()
      });

      final http.StreamedResponse response = await _httpClient.send(request);
      final int statusCode = response.statusCode;
      final String responseBody = await response.stream.bytesToString();

      if (statusCode == 200) {
        final Map<String, dynamic> responseData = jsonDecode(responseBody);
        await Clipboard.setData(
            ClipboardData(text: responseData["shareableLink"]));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sharable link copied to clipboard'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error sharing file'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      print('Error in handleShare: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An error occurred while sharing the file'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> handleDownload(fileData, index, BuildContext context) async {
    final fileId = fileData[index]['file_id'];
    print("File ID: $fileId");
    String url = "$_baseUrl/files/$fileId/download";
    final dio = Dio();

    // Choose download directory based on platform.
    Directory? downloadsDir;
    if (Platform.isAndroid) {
      downloadsDir = Directory('/storage/emulated/0/Download');
      if (!downloadsDir.existsSync()) {
        downloadsDir = await getExternalStorageDirectory();
      }
    } else if (Platform.isIOS) {
      // iOS does not have a public downloads folder.
      downloadsDir = await getApplicationDocumentsDirectory();
    } else if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      downloadsDir = await getDownloadsDirectory();
    } else {
      // Fallback for other platforms.
      downloadsDir = await getTemporaryDirectory();
    }

    if (downloadsDir == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to access storage')),
        );
      }
      return;
    }

    String folderPath = "${downloadsDir.path}/CycloneCloud";
    Directory(folderPath).createSync(recursive: true);
    String savePath = "$folderPath/$fileId";

    final file = File(savePath);

    if (file.existsSync()) {
      // File already exists, show options.
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('File Already Exists'),
            content: const Text(
                'Do you want to download a new version or keep the current one?'),
            actions: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await _performDownload(url, savePath, context);
                    },
                    child: const Text('Download New'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Download cancelled')),
                        );
                      }
                    },
                    child: const Text('Keep Existing'),
                  ),
                ],
              ),
            ],
          );
        },
      );
    } else {
      // File doesn't exist, proceed with download.
      await _performDownload(url, savePath, context);
    }
  }

  Future<void> _performDownload(
      String url, String savePath, BuildContext context) async {
    final dio = Dio();
    final ValueNotifier<double> progressNotifier = ValueNotifier<double>(0.0);
    late BuildContext dialogContext;
    // Show the progress dialog.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        dialogContext = context;
        return AlertDialog(
          title: const Text("Downloading"),
          content: ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (context, progress, child) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: progress,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 10),
                  Text("${(progress * 100).toStringAsFixed(0)}% completed"),
                ],
              );
            },
          ),
        );
      },
    );

    try {
      await dio.download(
        url,
        savePath,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          if (total != -1) {
            progressNotifier.value = received / total;
          }
        },
      );

      if (dialogContext.mounted) {
        // Use the root navigator to pop the dialog.
        Navigator.of(dialogContext, rootNavigator: true).pop();
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          SnackBar(content: Text('Download completed: $savePath')),
        );
        OpenFilex.open(savePath);
      }
    } catch (e) {
      if (dialogContext.mounted) {
        Navigator.of(dialogContext, rootNavigator: true).pop();
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(content: Text('Download failed.')),
        );
      }
    }
  }

  Future<void> handleRename(fileData, index, String newFilename,
      void Function() reloadFileList) async {
    final fileId = fileData[index]['file_id'];
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final accessToken = prefs.getString('accessToken');

    try {
      final request =
          http.Request('PUT', Uri.parse('$_baseUrl/files/$fileId/rename'));
      request.headers.addAll({
        'Content-Type': 'application/json; charset=UTF-8',
      });
      request.body = jsonEncode({
        'newName': newFilename,
        'owner_id': userId,
        'accessToken': accessToken,
        'device_name': await getDeviceName()
      });

      final http.StreamedResponse response = await _httpClient.send(request);
      final int statusCode = response.statusCode;
      final String responseBody = await response.stream.bytesToString();

      if (statusCode == 200) {
        fileData[index]['filename'] = newFilename;
        reloadFileList();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Successfully renamed file'),
            backgroundColor: Colors.green,
          ),
        );
        print('Rename response: $responseBody');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error renaming file'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      print('Error in handleRename: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An error occurred while renaming the file'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> handleDelete(
      fileData, index, void Function() reloadFileList) async {
    final id = fileData[index]['file_id'];
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id') ?? '';
    final accessToken = prefs.getString('accessToken');

    try {
      final request = http.Request('DELETE', Uri.parse('$_baseUrl/files/$id'));
      request.headers.addAll({
        'Content-Type': 'application/json; charset=UTF-8',
      });
      request.body = jsonEncode({
        'owner_id': userId,
        'accessToken': accessToken,
        'device_name': await getDeviceName()
      });

      final http.StreamedResponse response = await _httpClient.send(request);
      final int statusCode = response.statusCode;
      final String responseBody = await response.stream.bytesToString();

      if (statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('File deleted successfully'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 1)),
        );

        fileData.removeAt(index);
        reloadFileList();

        print('Delete response: $responseBody');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error deleting file'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      print('Error in handleDelete: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An error occurred while deleting the file'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  bool _isPickingFile = false;

  Future<void> uploadFile(void Function() handleRefresh, BuildContext context,
      [String folder = '']) async {
    if (_isPickingFile) {
      // Always check context.mounted before using it
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File picker is already active.')),
        );
      }
      return;
    }

    _isPickingFile = true;

    try {
      FilePickerResult? result =
          await FilePicker.platform.pickFiles(allowMultiple: true);

      if (result != null && result.files.isNotEmpty) {
        List<PlatformFile> files = result.files;
        final prefs = await SharedPreferences.getInstance();
        final accessToken = prefs.getString('accessToken');
        final userId = prefs.getString('user_id') ?? '';
        final ValueNotifier<double> uploadProgress = ValueNotifier<double>(0.0);

        // Check context.mounted before showing dialog
        if (!context.mounted) {
          _isPickingFile = false; // Reset flag if context is gone
          return;
        }
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            // Use a new context for the dialog builder
            return AlertDialog(
              title: const Text("Uploading Files..."),
              content: ValueListenableBuilder<double>(
                valueListenable: uploadProgress,
                builder: (context, progress, child) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(
                        value: progress,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 10),
                      Text("${(progress * 100).toStringAsFixed(0)}%"),
                    ],
                  );
                },
              ),
            );
          },
        );

        try {
          final deviceInfoPlugin = DeviceInfoPlugin();
          final deviceInfo = await deviceInfoPlugin.deviceInfo;
          final allInfo = deviceInfo.data;

          final http.MultipartRequest request =
              http.MultipartRequest('POST', Uri.parse('$_baseUrl/upload'));
          request.fields['owner_id'] = userId;
          request.fields['folder'] = folder;
          request.fields['device_name'] = allInfo.toString();
          if (accessToken != null && accessToken.isNotEmpty) {
            request.fields['accessToken'] = accessToken;
          }
          int totalBytes = files.fold(0, (sum, file) => sum + file.size);
          int uploadedBytes = 0;

          List<Future<void>> uploadFutures = [];

          for (PlatformFile file in files) {
            if (file.bytes == null) {
              print("No file data available for file: ${file.name}");
              continue;
            }
            final mimeType = lookupMimeType(file.name);
            final contentType = mimeType != null
                ? MediaType.parse(mimeType)
                : MediaType('application', 'octet-stream');

            var stream = http.ByteStream(Stream.fromIterable([file.bytes!]));
            var length = file.bytes!.length;

            uploadFutures.add(Future.sync(() async {
              var requestFile = http.MultipartFile(
                'files', // This should match the field name on your server for files
                stream,
                length,
                filename: file.name,
                contentType: contentType,
              );
              request.files.add(requestFile);
              // Update progress based on individual file upload, if you want real-time per-file progress
              // For overall progress, the existing logic is fine.
            }));
          }
          await Future.wait(uploadFutures);

          // Update overall progress just before sending the request
          // This part might need adjustment if you want progress during the actual network send,
          // which requires a custom http client that exposes stream progress.
          // For now, it updates after all files are added to the request.
          uploadProgress.value = 1.0; // Assume 100% when all files are prepared

          print("Request Fields: ${request.fields}");
          print(
              "Request Files: ${request.files.map((f) => f.filename).toList()}");

          final http.StreamedResponse response = await request.send();
          final int statusCode = response.statusCode;
          final String responseBody = await response.stream.bytesToString();

          // Check context.mounted before popping dialog
          if (context.mounted) {
            Navigator.of(context).pop(); // Close the dialog
          }
          print("Response from server: $responseBody");

          if (statusCode == 200) {
            handleRefresh();
            clearFilePickerCache();
            // Check context.mounted before showing snackbar
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Files uploaded successfully!')),
              );
            }
          } else {
            clearFilePickerCache(); // Clear cache even on failure
            // Check context.mounted before showing snackbar
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(
                        'Upload failed: $statusCode\nResponse: $responseBody')),
              );
            }
          }
        } catch (e) {
          // Check context.mounted before popping dialog
          if (context.mounted) {
            Navigator.of(context).pop(); // Close the dialog
          }
          _handleNetworkError(e);
          clearFilePickerCache();
          // Check context.mounted before showing snackbar
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Network error during upload.')),
            );
          }
        }
      } else {
        clearFilePickerCache();
        // Check context.mounted before showing snackbar
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File upload canceled.')),
          );
        }
      }
    } catch (e) {
      print('Error in uploadFile: $e');
      // Check context.mounted before showing snackbar
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'An unexpected error occurred during file picking or upload.'),
          ),
        );
      }
    } finally {
      _isPickingFile = false;
    }
  }

  void _handleNetworkError(Object e) {
    print("Network error: ${e.toString()}");
  }
}

Future<void> clearFilePickerCache() async {
  try {
    await FilePicker.platform.clearTemporaryFiles();
    print('File picker cache cleared.');
  } catch (e) {
    print('Error clearing file picker cache: $e');
  }
}
