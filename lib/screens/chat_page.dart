import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show decodeImageFromList;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:web_socket_client/web_socket_client.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:intl/intl.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({Key? key, required this.name, required this.id})
      : super(key: key);

  final String name;
  final String id;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  late WebSocket socket;
  final String serverUrl = 'ws://10.200.74.225:8765';

  final List<types.Message> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  bool _isConnected = false;
  bool _isTyping = false;
  bool _isAttachingFile = false;
  
  late types.User me;
  late types.User otherUser;

  final Set<String> _seenMessageIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    me = types.User(
      id: widget.id,
      firstName: widget.name,
      imageUrl: 'https://ui-avatars.com/api/?name=${widget.name}&background=random',
    );

    otherUser = types.User(
      id: 'default',
      firstName: 'Other User',
      imageUrl: 'https://ui-avatars.com/api/?name=Other+User&background=random',
    );

    _initializeWebSocket();
    _loadMessages();

    Connectivity().checkConnectivity().then(_updateConnectionStatus);

    Connectivity().onConnectivityChanged.listen(_updateConnectionStatus);
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_isConnected) {
        _initializeWebSocket();
      }
    } else if (state == AppLifecycleState.paused) {
      _sendTypingStatus(false);
    }
  }
  
  void _updateConnectionStatus(ConnectivityResult result) {
    final bool isConnected = result != ConnectivityResult.none;
    
    if (isConnected && !_isConnected) {
      _initializeWebSocket();
    }
    
    setState(() {
      _isConnected = isConnected;
    });
  }
  
  void _initializeWebSocket() {
    try {
      socket.close();
    } catch (e) {
      print("Error closing socket: $e");
    }

    socket = WebSocket(Uri.parse(serverUrl));

    socket.connection.listen((state) {
      setState(() {
        _isConnected = state is Connected;
      });
      
      if (state is Connected) {
        _sendOnlineStatus(true);
      }
    });

    socket.messages.listen(
      (incomingMessage) {
        if (incomingMessage is String) {
          try {
            final parts = incomingMessage.split(' from ');
            final jsonString = parts[0];

            final data = jsonDecode(jsonString);
            final id = data['id'];
            final msg = data['msg'];
            final nick = data['nick'] ?? id;
            final type = data['type'] ?? 'text';

            if (type == 'typing') {
              if (id != me.id) {
                setState(() {
                  otherUser = types.User(
                    id: id,
                    firstName: nick,
                    imageUrl: 'https://ui-avatars.com/api/?name=${Uri.encodeComponent(nick)}&background=random',
                  );
                  _isTyping = msg == 'true';
                });
              }
              return;
            }
            
            // Handle read receipts
            if (type == 'read_receipt') {
              _handleReadReceipt(data);
              return;
            }

            // If message is not from me, handle it
            if (id != me.id) {
              setState(() {
                otherUser = types.User(
                  id: id,
                  firstName: nick,
                  imageUrl: 'https://ui-avatars.com/api/?name=${Uri.encodeComponent(nick)}&background=random',
                );
              });
              onMessageReceived(msg, type, data['id']);

              _sendReadReceipt(data['id']);
            }
          } catch (e) {
            print("Error processing message: $e");
          }
        }
      },
      onError: (error) {
        print("WebSocket error: $error");
        setState(() {
          _isConnected = false;
        });
      },
      onDone: () {
        setState(() {
          _isConnected = false;
        });
        // Attempt to reconnect after a delay
        Future.delayed(const Duration(seconds: 5), _initializeWebSocket);
      },
    );
  }

  Future<void> _loadMessages() async {
    final welcomeMessage = types.TextMessage(
      author: otherUser,
      id: 'welcome',
      text: 'Welcome to the chat! Messages are end-to-end encrypted.',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: types.Status.seen,
    );
    
    setState(() {
      _messages.insert(0, welcomeMessage);
    });
  }

  String randomString() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(255));
    return base64UrlEncode(values);
  }

  void onMessageReceived(String message, String type, [String? messageId]) {
    types.Message newMessage;
    final id = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

    if (type == 'image') {
      newMessage = types.ImageMessage(
        author: otherUser,
        id: id,
        uri: message,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        name: 'Image',
        size: 0,
        width: 0,
        height: 0,
        status: types.Status.delivered,
      );
    } else if (type == 'file') {
      newMessage = types.FileMessage(
        author: otherUser,
        id: id,
        uri: message,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        name: 'File',
        size: 0,
        mimeType: 'application/octet-stream',
        status: types.Status.delivered,
      );
    } else {
      newMessage = types.TextMessage(
        author: otherUser,
        id: id,
        text: message,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        status: types.Status.delivered,
      );
    }

    _addMessage(newMessage);

  }

  void _addMessage(types.Message message) {
    setState(() {
      _messages.insert(0, message);
    });

    if (message.author.id != me.id) {
      _seenMessageIds.add(message.id);
    }
  }

  void _sendMessageCommon(types.Message message) {
    String content;
    String type;

    if (message is types.TextMessage) {
      content = message.text;
      type = 'text';
    } else if (message is types.ImageMessage) {
      content = message.uri;
      type = 'image';
    } else if (message is types.FileMessage) {
      content = message.uri;
      type = 'file';
    } else {
      print("Unsupported message type: ${message.toString()}");
      return;
    }

    final payload = {
      'id': me.id,
      'msg': content,
      'nick': me.firstName,
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      'type': type,
      'message_id': message.id,
    };

    if (_isConnected) {
      socket.send(jsonEncode(payload));
      
      setState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          final updatedMessage = _copyMessageWithStatus(_messages[index], types.Status.sent);
          _messages[index] = updatedMessage;
        }
      });
    } else {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          final updatedMessage = _copyMessageWithStatus(_messages[index], types.Status.error);
          _messages[index] = updatedMessage;
        }
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Network unavailable. Message not sent.'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              final index = _messages.indexWhere((m) => m.id == message.id);
              if (index != -1) {
                _sendMessageCommon(_messages[index]);
              }
            },
          ),
        ),
      );
    }
  }
  
  types.Message _copyMessageWithStatus(types.Message message, types.Status status) {
    if (message is types.TextMessage) {
      return message.copyWith(status: status);
    } else if (message is types.ImageMessage) {
      return message.copyWith(status: status);
    } else if (message is types.FileMessage) {
      return message.copyWith(status: status);
    }
    return message;
  }

  void _handleSendPressed(types.PartialText partial) {
    final text = partial.text.trim();
    if (text.isEmpty) return;
    
    final textMessage = types.TextMessage(
      author: me,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      id: randomString(),
      text: text,
      status: types.Status.sending,
      metadata: {
        'senderName': me.firstName,
      },
    );
    
    _addMessage(textMessage);
    
    _sendMessageCommon(textMessage);
    
    _sendTypingStatus(false);
  }

  void _handleAttachmentPressed() {
    setState(() {
      _isAttachingFile = true;
    });
    
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: SizedBox(
            height: 180,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: Text(
                    'Send attachment',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.deepPurple,
                    child: Icon(Icons.photo, color: Colors.white),
                  ),
                  title: const Text('Photo'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _handleImageSelection();
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.deepPurple,
                    child: Icon(Icons.attach_file, color: Colors.white),
                  ),
                  title: const Text('File'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _handleFileSelection();
                  },
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      setState(() {
        _isAttachingFile = false;
      });
    });
  }

  Future<void> _handleFileSelection() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final fileName = result.files.single.name;
        final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';

        final message = types.FileMessage(
          author: me,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          id: randomString(),
          mimeType: mimeType,
          name: fileName,
          size: result.files.single.size,
          uri: filePath,
          status: types.Status.sending,
        );

        _addMessage(message);
        _sendMessageCommon(message);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error selecting file: $e')),
      );
    }
  }

  Future<void> _handleImageSelection() async {
    try {
      final picker = ImagePicker();
      final pickedImage = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1440,
        imageQuality: 70,
      );
      
      if (pickedImage != null) {
        final bytes = await pickedImage.readAsBytes();
        final decodedImg = await decodeImageFromList(bytes);

        final message = types.ImageMessage(
          author: me,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          height: decodedImg.height.toDouble(),
          id: randomString(),
          name: pickedImage.name,
          size: bytes.length,
          uri: pickedImage.path,
          width: decodedImg.width.toDouble(),
          status: types.Status.sending,
        );
        
        _addMessage(message);
        _sendMessageCommon(message);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error selecting image: $e')),
      );
    }
  }
  
  void _handleReadReceipt(Map<String, dynamic> data) {
    final messageId = data['message_id'];
    if (messageId != null) {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          final message = _messages[index];
          final updatedMessage = _copyMessageWithStatus(message, types.Status.seen);
          _messages[index] = updatedMessage;
        }
      });
    }
  }
  
  void _sendReadReceipt(String messageId) {
    final payload = {
      'id': me.id,
      'type': 'read_receipt',
      'message_id': messageId,
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    };
    
    if (_isConnected) {
      socket.send(jsonEncode(payload));
    }
  }
  
  void _sendTypingStatus(bool isTyping) {
    final payload = {
      'id': me.id,
      'nick': me.firstName,
      'type': 'typing',
      'msg': isTyping.toString(),
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    };
    
    if (_isConnected) {
      socket.send(jsonEncode(payload));
    }
  }
  
  void _sendOnlineStatus(bool isOnline) {
    final payload = {
      'id': me.id,
      'nick': me.firstName,
      'type': 'online_status',
      'msg': isOnline.toString(),
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    };
    
    if (_isConnected) {
      socket.send(jsonEncode(payload));
    }
  }
  
  void _handleMessageTap(BuildContext _, types.Message message) async {
    if (message is types.FileMessage) {
      await OpenFilex.open(message.uri);
    }
  }
  
  void _handlePreviewDataFetched(
    types.TextMessage message,
    types.PreviewData previewData,
  ) {
    final index = _messages.indexWhere((element) => element.id == message.id);
    if (index != -1) {
      final updatedMessage = (_messages[index] as types.TextMessage).copyWith(
        previewData: previewData,
      );
      
      setState(() {
        _messages[index] = updatedMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final customTheme = DefaultChatTheme(
      primaryColor: Colors.deepPurple,
      secondaryColor: Colors.grey[200]!,
      messageBorderRadius: 16,
      inputBackgroundColor: Colors.deepPurple[50]!,
      inputTextCursorColor: Colors.deepPurple,
      userAvatarNameColors: [
        Colors.purple,
        Colors.blueGrey,
        Colors.teal,
      ],
      sentMessageBodyTextStyle: const TextStyle(color: Colors.white), // text color in my bubble
      receivedMessageBodyTextStyle: const TextStyle(color: Colors.black87), // text color in other bubble
      sentMessageCaptionTextStyle: const TextStyle(color: Colors.white70),
      inputTextStyle: const TextStyle(fontSize: 16),
      inputTextColor: Colors.black87,
      seenIcon: const Icon(Icons.done_all, size: 16, color: Colors.deepPurple),
      deliveredIcon: const Icon(Icons.done, size: 16, color: Colors.grey),
      sendingIcon: const Icon(Icons.access_time, size: 16, color: Colors.grey),
      errorIcon: const Icon(Icons.error_outline, size: 16, color: Colors.red),
    );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              otherUser.firstName ?? 'Chat',
              style: const TextStyle(color: Colors.white),
            ),
            if (_isTyping)
              const Text(
                'typing...',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              )
            else if (_isConnected)
              const Text(
                'online',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              )
            else
              const Text(
                'offline',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        backgroundColor: Colors.deepPurple,
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) {
                  return SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.delete),
                          title: const Text('Clear chat'),
                          onTap: () {
                            setState(() {
                              _messages.clear();
                            });
                            Navigator.pop(context);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.block),
                          title: const Text('Block user'),
                          onTap: () {
                            Navigator.pop(context);
                          },
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_isConnected)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              color: Colors.orange,
              width: double.infinity,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.signal_wifi_off, size: 14, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    'Connecting...',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Chat(
              theme: customTheme,
              messages: _messages,
              onAttachmentPressed: _handleAttachmentPressed,
              onMessageTap: _handleMessageTap,
              onPreviewDataFetched: _handlePreviewDataFetched,
              onSendPressed: _handleSendPressed,
              showUserAvatars: true,
              showUserNames: true,
              user: me,
              isAttachmentUploading: _isAttachingFile,
              dateLocale: 'en_US',
              timeFormat: DateFormat.Hm(),
              usePreviewData: true,
              inputOptions: InputOptions(
                sendButtonVisibilityMode: SendButtonVisibilityMode.always,
              ),
              typingIndicatorOptions: TypingIndicatorOptions(
                typingUsers: _isTyping ? [otherUser] : [],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _sendOnlineStatus(false); // Mark as offline
    socket.close(); // Close the WebSocket
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}