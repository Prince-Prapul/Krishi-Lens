package ar.labs.krishilens;

import androidx.appcompat.app.AppCompatActivity;

import android.os.Bundle;
import android.widget.GridView;
import android.widget.ImageView;

import java.util.ArrayList;
public class MainActivity extends AppCompatActivity {
    GridView coursesGV;
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        coursesGV = findViewById(R.id.idGVcourses);

        ArrayList<CourseModel> courseModelArrayList = new ArrayList<CourseModel>();
        courseModelArrayList.add(new CourseModel("Tomato Leaves", R.mipmap.tomato,"Tomato Leaves"));
        courseModelArrayList.add(new CourseModel("Rice Paddy", R.mipmap.paddy,"Rice Paddy"));
        courseModelArrayList.add(new CourseModel("Corn", R.mipmap.corn,"Corn Leaves"));
        courseModelArrayList.add(new CourseModel("Cassava", R.mipmap.cassava,"Cassava"));
        courseModelArrayList.add(new CourseModel("Help", R.mipmap.help,"Help"));
        courseModelArrayList.add(new CourseModel("Contact Us", R.mipmap.contact,"Contact Us"));
        CourseGVAdapter adapter = new CourseGVAdapter(this, courseModelArrayList);
        coursesGV.setAdapter(adapter);
    }
}